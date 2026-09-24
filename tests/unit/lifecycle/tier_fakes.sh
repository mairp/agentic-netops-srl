#!/usr/bin/env bash
# tier_fakes.sh — a stateful fake kubectl, with a fake analytics store behind `kubectl exec`, for the
# intent tier's offline suites (T174: tier_purge_test.sh, tier_phase_order_test.sh). Not a suite
# itself (no _test.sh suffix): sourced by them, AFTER tests/unit/lifecycle/fakes.sh, whose fake
# docker / kind / containerlab it keeps and whose state layout it shares:
#
#   state/k8s/<cluster>/<namespace|_>/<kind>/<name>.json      one object per file
#   state/calls.log                                           "kubectl <args…>" per call, plus
#                                                             "APPLY <Kind>/<name>" per applied object
#   state/store/{mode,newest,tables/<table>.ndjson}           the fake ClickHouse (see below)
#
#   tier_fakes::install <dir>   (after fakes::install <dir>) replaces <dir>/bin/kubectl
#   tier_fakes::obj <cluster> <ns|_> <kind> <json>            plant an object (kind = normalised)
#
# kubectl verbs understood: get (one object or a list; -o json | name | jsonpath uid; -A; -l),
# apply -f - (multi-document YAML or JSON), delete (several names; --ignore-not-found), scale,
# rollout status, exec (the store), kustomize <dir> (the resources of its kustomization.yaml,
# concatenated), config current-context.
#
# Networks (kind `network`) carry a test-only `.fake.finalize`: ok (default: the finalizer
# completes at once, and — as the provider's finalizer does — the claims labelled with the
# Network's correlation id are released), unreachable (Deleting=True/TargetUnreachable naming
# target leaf02), holder (Deleting=True/HolderPresent naming the holder), slow
# (Deleting=True/RemovingConfiguration). A deletion-marked Network whose finalize is flipped to ok
# by the test completes on the next read. FAKE_APPEAR_ON_SCALE=<json file>: the first `scale` call
# plants that Network (a service submitted between the purge's two lists).
#
# The store: `kubectl exec … <pod> -c clickhouse -- bash -c <script> <query>` (the credentials are the
# container's env, never argv). mode: ok | unqueryable (every query hangs: the process becomes `sleep`) |
# query-error (SELECT 1 answers, every other query fails) | short (the row export drops a row).
# `newest`, when present, is what the store reports as its newest row's timestamp.
#
# Markers (for "before" assertions the call order alone cannot make): on deleting Secret
# operator-credentials the fake logs `MARK usernames-record-present=<yes|no>`; on deleting the
# store (statefulset clickhouse, namespace agentic-netops-agents, or the cluster via kind) it logs
# `MARK audit-export-present=<yes|no>` — both looked up under $EVIDENCE_ROOT.

tier_fakes::install() {
  local d="$1"
  mkdir -p "$d/state/store/tables"
  echo ok >"$d/state/store/mode"
  cat >"$d/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
printf 'kubectl %s\n' "$*" >>"$FAKE_STATE/calls.log"
ctx="" ns="" sel="" out="" all_ns=false ignore_nf=false replicas="" file=""
pos=() rest=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --) shift; rest=("$@"); break ;;
    --context) ctx="$2"; shift 2 ;;
    --context=*) ctx="${1#*=}"; shift ;;
    -n|--namespace) ns="$2"; shift 2 ;;
    -l|--selector) sel="$2"; shift 2 ;;
    -o|--output) out="$2"; shift 2 ;;
    -o*) out="${1#-o}"; out="${out#=}"; shift ;;
    -A|--all-namespaces) all_ns=true; shift ;;
    --ignore-not-found|--ignore-not-found=true) ignore_nf=true; shift ;;
    --replicas=*) replicas="${1#*=}"; shift ;;
    --replicas) replicas="$2"; shift 2 ;;
    -f|--filename) file="$2"; shift 2 ;;
    --request-timeout|--field-manager|--timeout|-c|--container) shift 2 ;;
    -*) shift ;;
    *) pos+=("$1"); shift ;;
  esac
done
verb="${pos[0]:-}"
if [[ "$verb" == config ]]; then
  [[ "${pos[1]:-}" == current-context && -n "${FAKE_CURRENT_CONTEXT:-}" ]] && { echo "$FAKE_CURRENT_CONTEXT"; exit 0; }
  exit 1
fi
if [[ "$verb" == kustomize ]]; then
  dir="${pos[1]}"
  first=1
  while IFS= read -r r; do
    [[ -n "$r" ]] || continue
    [[ $first -eq 1 ]] || echo '---'
    first=0
    cat "$dir/$r"
  done < <(yq -r '.resources[]' "$dir/kustomization.yaml")
  exit 0
fi
cluster="${ctx#kind-}"
K="$FAKE_STATE/k8s/$cluster"
[[ -n "$cluster" && -d "$K" ]] || { echo "error: context \"$ctx\" does not exist or the cluster is unreachable" >&2; exit 1; }
norm() {
  local k="${1,,}"
  case "$k" in
    ns|namespace|namespaces) echo namespace ;; secret|secrets) echo secret ;; node|nodes) echo node ;;
    sts|statefulset|statefulsets|statefulset.apps|statefulsets.apps) echo statefulset ;;
    deploy|deployment|deployments|deployment.apps|deployments.apps) echo deployment ;;
    svc|service|services) echo service ;; cm|configmap|configmaps) echo configmap ;;
    networks.fabric.agentic-netops.io|network|networks) echo network ;;
    fabrics.fabric.agentic-netops.io|fabric|fabrics) echo fabric ;;
    identifierclaims.fabric.agentic-netops.io|identifierclaim|identifierclaims) echo identifierclaim ;;
    vlanclaims.vlan.be.kuid.dev|vlanclaim|vlanclaims) echo vlanclaim ;;
    genidclaims.genid.be.kuid.dev|genidclaim|genidclaims) echo genidclaim ;;
    validatingadmissionpolicy|validatingadmissionpolicies|validatingadmissionpolicies.admissionregistration.k8s.io) echo validatingadmissionpolicy ;;
    validatingadmissionpolicybinding|validatingadmissionpolicybindings|validatingadmissionpolicybindings.admissionregistration.k8s.io) echo validatingadmissionpolicybinding ;;
    role|roles|roles.rbac.authorization.k8s.io) echo role ;;
    rolebinding|rolebindings|rolebindings.rbac.authorization.k8s.io) echo rolebinding ;;
    pod|pods) echo pod ;;
    *) echo "$k" ;;
  esac
}
cluster_scoped() { case "$1" in namespace|node|validatingadmissionpolicy|validatingadmissionpolicybinding) return 0 ;; *) return 1 ;; esac; }
scope() { if cluster_scoped "$1"; then echo _; else echo "${ns:-default}"; fi; }
sel_match() { # <file>
  [[ -z "$sel" ]] && return 0
  local IFS=, s
  for s in $sel; do
    if [[ "$s" == '!'* ]]; then
      jq -e --arg k "${s#!}" '(.metadata.labels // {}) | has($k) | not' "$1" >/dev/null || return 1
    elif [[ "$s" == *=* ]]; then
      jq -e --arg k "${s%%=*}" --arg v "${s#*=}" '(.metadata.labels // {})[$k] == $v' "$1" >/dev/null || return 1
    else
      jq -e --arg k "$s" '(.metadata.labels // {}) | has($k)' "$1" >/dev/null || return 1
    fi
  done
}
mark_evidence() { # <glob> — yes when a file matching it exists under the evidence root
  if [[ -n "${EVIDENCE_ROOT:-}" && -n "$(find "$EVIDENCE_ROOT" -name "$1" 2>/dev/null | head -1)" ]]; then echo yes; else echo no; fi
}
# the provider's finalizer, simulated: a deletion-marked Network whose finalize is ok completes,
# releasing the claims labelled with its correlation id
sweep_networks() {
  local f cid c
  for f in "$K"/*/network/*.json; do
    [[ -f "$f" ]] || continue
    jq -e '.metadata.deletionTimestamp != null and ((.fake.finalize // "ok") == "ok")' "$f" >/dev/null || continue
    cid="$(jq -r '.metadata.labels["agentic-netops.io/correlation-id"] // ""' "$f")"
    rm -f "$f"
    if [[ -n "$cid" ]]; then
      for c in "$K"/*/identifierclaim/*.json "$K"/*/vlanclaim/*.json "$K"/*/genidclaim/*.json; do
        [[ -f "$c" ]] || continue
        jq -e --arg c "$cid" '.metadata.labels["agentic-netops.io/correlation-id"] == $c' "$c" >/dev/null && rm -f "$c"
      done
    fi
  done
}
emit() { # <file> — one object in the requested output
  case "$out" in
    json) cat "$1" ;;
    name) echo "$(jq -r '.kind | ascii_downcase' "$1")/$(jq -r '.metadata.name' "$1")" ;;
    jsonpath=*metadata.uid*) jq -r '.metadata.uid // ("uid-" + .metadata.name)' "$1" ;;
    *) jq -r '.metadata.name' "$1" ;;
  esac
}
case "$verb" in
  get)
    sweep_networks
    kind="$(norm "${pos[1]%%,*}")" name="${pos[2]:-}"
    if [[ -n "$name" ]]; then
      if [[ "$kind" == namespace && "$name" == kube-system && "$out" == jsonpath=* ]]; then echo "uid-$cluster-kube-system"; exit 0; fi
      f="$K/$(scope "$kind")/$kind/$name.json"
      [[ -f "$f" ]] || { echo "Error from server (NotFound): $kind \"$name\" not found" >&2; exit 1; }
      emit "$f"
    else
      files=()
      if $all_ns; then
        for f in "$K"/*/"$kind"/*.json; do [[ -f "$f" ]] && sel_match "$f" && files+=("$f"); done
      else
        for f in "$K/$(scope "$kind")/$kind"/*.json; do [[ -f "$f" ]] && sel_match "$f" && files+=("$f"); done
      fi
      if [[ "$out" == json ]]; then
        if [[ ${#files[@]} -eq 0 ]]; then echo '{"apiVersion":"v1","kind":"List","items":[]}'; else jq -s '{apiVersion: "v1", kind: "List", items: .}' "${files[@]}"; fi
      else
        for f in "${files[@]}"; do emit "$f"; done
      fi
    fi ;;
  apply)
    [[ "$file" == - ]] || { echo "fake kubectl: apply supports -f - only" >&2; exit 1; }
    docs="$(yq -o=json -I=0 'select(. != null)' - )" || { echo "fake kubectl: unparsable apply input" >&2; exit 1; }
    while IFS= read -r obj; do
      [[ -n "$obj" && "$obj" != null ]] || continue
      kindc="$(jq -r '.kind' <<<"$obj")"; name="$(jq -r '.metadata.name' <<<"$obj")"
      kind="$(norm "$kindc")"
      ons="$(jq -r '.metadata.namespace // "default"' <<<"$obj")"
      cluster_scoped "$kind" && ons=_
      if [[ -n "${FAKE_APPLY_FAIL:-}" && "$kindc/$name" == "$FAKE_APPLY_FAIL" ]]; then echo "fake apply failure: $kindc/$name" >&2; exit 1; fi
      if [[ "$ons" != _ && ! -f "$K/_/namespace/$ons.json" ]]; then
        echo "Error from server (NotFound): namespaces \"$ons\" not found" >&2; exit 1
      fi
      printf 'APPLY %s/%s\n' "$kindc" "$name" >>"$FAKE_STATE/calls.log"
      mkdir -p "$K/$ons/$kind"
      printf '%s\n' "$obj" >"$K/$ons/$kind/$name.json"
      echo "$kind/$name serverside-applied"
    done < <(jq -c 'if type == "object" and .kind == "List" then .items[] else . end' <<<"$docs")
    ;;
  delete)
    kind="$(norm "${pos[1]}")"
    rc=0
    for name in "${pos[@]:2}"; do
      dir="$K/$(scope "$kind")/$kind"; f="$dir/$name.json"
      if [[ ! -f "$f" ]]; then
        $ignore_nf && continue
        echo "Error from server (NotFound): $kind \"$name\" not found" >&2; rc=1; continue
      fi
      case "$kind/$name" in
        secret/operator-credentials) echo "MARK usernames-record-present=$(mark_evidence 'operator-usernames-*.json')" >>"$FAKE_STATE/calls.log" ;;
        statefulset/clickhouse|namespace/agentic-netops-agents) echo "MARK audit-export-present=$(mark_evidence 'audit-export-*.json')" >>"$FAKE_STATE/calls.log" ;;
      esac
      if [[ "$kind" == network ]]; then
        fin="$(jq -r '.fake.finalize // "ok"' "$f")"
        now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        case "$fin" in
          unreachable) cond='{"type":"Deleting","status":"True","reason":"TargetUnreachable","message":"configuration removed from every reachable target; target leaf02 is unreachable"}' ;;
          holder) cond='{"type":"Deleting","status":"True","reason":"HolderPresent","message":"held by agentic-netops-intent/acl-holder, bound to leaf01 ethernet-1/1.10"}' ;;
          slow) cond='{"type":"Deleting","status":"True","reason":"RemovingConfiguration","message":"removing configuration from leaf01, leaf02"}' ;;
          *) cond="" ;;
        esac
        jq --arg t "$now" '.metadata.deletionTimestamp = $t' "$f" >"$f.t" && mv "$f.t" "$f"
        if [[ -n "$cond" ]]; then
          jq --argjson c "$cond" '.status.conditions = [{"type":"Ready","status":"False","reason":"Deleting","message":"being removed"}, $c]' "$f" >"$f.t" && mv "$f.t" "$f"
        fi
        sweep_networks
        echo "network.fabric.agentic-netops.io \"$name\" deleted"
        continue
      fi
      rm -f "$f"
      [[ "$kind" == namespace ]] && rm -rf "${K:?}/$name"
      echo "$kind \"$name\" deleted"
    done
    exit "$rc" ;;
  scale)
    obj="${pos[1]}"; kind="$(norm "${obj%%/*}")"; name="${obj#*/}"
    [[ "$obj" == */* ]] || { kind="$(norm "${pos[1]}")"; name="${pos[2]}"; }
    f="$K/${ns:-default}/$kind/$name.json"
    [[ -f "$f" ]] || { echo "Error from server (NotFound): $kind \"$name\" not found" >&2; exit 1; }
    jq --argjson r "${replicas:-1}" '.spec.replicas = $r' "$f" >"$f.t" && mv "$f.t" "$f"
    if [[ -n "${FAKE_APPEAR_ON_SCALE:-}" && -f "$FAKE_APPEAR_ON_SCALE" ]]; then
      a="$(cat "$FAKE_APPEAR_ON_SCALE")"; rm -f "$FAKE_APPEAR_ON_SCALE"
      mkdir -p "$K/$(jq -r '.metadata.namespace' <<<"$a")/network"
      printf '%s\n' "$a" >"$K/$(jq -r '.metadata.namespace' <<<"$a")/network/$(jq -r '.metadata.name' <<<"$a").json"
    fi
    echo "$kind.apps/$name scaled" ;;
  rollout)
    obj="${pos[2]}"; kind="$(norm "${obj%%/*}")"; name="${obj#*/}"
    f="$K/${ns:-default}/$kind/$name.json"
    [[ -f "$f" ]] || { echo "Error from server (NotFound): $kind \"$name\" not found" >&2; exit 1; }
    if [[ -e "$FAKE_STATE/never-ready/$kind-$name" ]]; then
      echo "error: timed out waiting for the condition on ${kind}s/$name" >&2; exit 1
    fi
    echo "$kind \"$name\" successfully rolled out" ;;
  exec)
    pod="${pos[1]}"
    [[ -f "$K/${ns:-default}/statefulset/${pod%-0}.json" ]] || { echo "Error from server (NotFound): pods \"$pod\" not found" >&2; exit 1; }
    # the query is the argument after the pod's `bash -c <script>`; credentials come from the
    # container's env inside the pod and never appear here
    query="${rest[3]:-}"
    S="$FAKE_STATE/store"; mode="$(cat "$S/mode" 2>/dev/null || echo ok)"
    [[ "$mode" == unqueryable ]] && exec sleep 3600
    if [[ "$query" == "SELECT 1" ]]; then echo 1; exit 0; fi
    [[ "$mode" == query-error ]] && { echo "Code: 60. DB::Exception: Unknown table expression identifier (UNKNOWN_TABLE)" >&2; exit 60; }
    table="$(sed -nE 's/.*`([^`]+)`\.`([^`]+)`.*/\2/p' <<<"$query")"
    case "$query" in
      *system.tables*) for t in "$S"/tables/*.ndjson; do [[ -f "$t" ]] && basename "$t" .ndjson; done; exit 0 ;;
      *"count()"*)
        t="$S/tables/$table.ndjson"
        [[ -f "$t" ]] || { echo "Code: 60. DB::Exception: Table otel.$table does not exist" >&2; exit 60; }
        n="$(grep -c . "$t" || true)"
        if [[ -f "$S/newest" ]]; then ts="$(cat "$S/newest")"
        elif [[ "$n" -gt 0 ]]; then ts="$(jq -rs 'map(.Timestamp) | max' "$t")"
        else ts='\N'; fi                     # maxOrNull on an empty table: NULL
        printf '%s\t%s\n' "$n" "$ts" ;;
      *JSONEachRow*)
        t="$S/tables/$table.ndjson"
        [[ -f "$t" ]] || { echo "Code: 60. DB::Exception: Table otel.$table does not exist" >&2; exit 60; }
        if [[ "$mode" == short ]]; then sed '$d' "$t"; else cat "$t"; fi ;;
      *) echo "fake store: unrecognised query: $query" >&2; exit 62 ;;
    esac ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$d/bin/kubectl"
  # the full off.sh deletes the store with the cluster: mark whether an export exists at that moment
  local kindbin="$d/bin/kind"
  sed -i '2a [[ "$1 ${2:-}" == "delete cluster" ]] \&\& echo "MARK audit-export-present=$([[ -n "${EVIDENCE_ROOT:-}" \&\& -n "$(find "$EVIDENCE_ROOT" -name "audit-export-*.json" 2>/dev/null | head -1)" ]] \&\& echo yes || echo no)" >>"$FAKE_STATE/calls.log"' "$kindbin"
}

# tier_fakes::obj <cluster> <ns|_> <kind> <json> — plant an object (metadata.name from the JSON)
tier_fakes::obj() {
  local cluster="$1" ns="$2" kind="$3" json="$4" name
  name="$(jq -r '.metadata.name' <<<"$json")"
  mkdir -p "$FAKE_STATE/k8s/$cluster/$ns/$kind"
  printf '%s\n' "$json" >"$FAKE_STATE/k8s/$cluster/$ns/$kind/$name.json"
}
