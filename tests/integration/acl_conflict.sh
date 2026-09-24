#!/usr/bin/env bash
# tests/integration/acl_conflict.sh — the binding conflict is refused by the control plane before
# anything is created (T114; quickstart.md §13; contracts/acl-render-contract.md §6; SC-015,
# FR-043, NFR-013). The tier half (the deployer's pre-flight refusing it first) is
# agents/tests/e2e/test_acl_e2e.py step d; this is the declarative control plane's own guard.
#
# Behind `make test-acl-conflict`. Given a holder Network (default agentic-netops-services/lab-acl)
# whose first access list binds (node, port, subinterface, direction, family) on its first
# attachment, a second, standalone Network acl-conflict-probe asking for a list on exactly that key:
#   AC-refused   `kubectl create` of the candidate is refused by admission, the refusal naming
#                `Network <holder>` and the occupied binding, and `kubectl get` finds no such object
#                (a create admission did accept would be deleted again and FAIL the check)
#   AC-unchanged the namespace's Network list is identical before and after
#   AC-accepted  the exclusivity is keyed, not blanket: the same candidate in the OTHER address
#                family (a different key) is admitted — server-side dry-run, nothing is created
# Negative controls first (NFR-013): AC-refused against the other-family candidate (admitted, so
# the refusal check must FAIL — sent as a server dry-run, nothing persisted), and AC-accepted against
# the conflicting candidate (refused, so it must FAIL). A control that passes refuses the run.
#
# Usage: acl_conflict.sh [<namespace>/<holder>]
# Environment: EVIDENCE_DIR, CLUSTER_NAME, LAB_NAME, KUBECTL.
# Exit: 0 refused as required; 1 a check failed; 2 usage; 3 refused (holder unreadable or carrying
#   no access list, a candidate already present, a negative control that passed).
set -euo pipefail

AC_HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
AC_ROOT="$(cd -- "$AC_HERE/../.." && pwd)"
AC_SELF="$AC_HERE/$(basename -- "${BASH_SOURCE[0]}")"
AC_LIB="$AC_HERE/lib/acl.sh"
# shellcheck source=lib/acl.sh
source "$AC_LIB"
# shellcheck source=../../scripts/lib/log.sh
source "$AC_ROOT/scripts/lib/log.sh"
# shellcheck source=../../scripts/lib/evidence.sh
source "$AC_ROOT/scripts/lib/evidence.sh"
LOG_PHASE="${LOG_PHASE:-acl-conflict}"

AC_CANDIDATE="acl-conflict-probe"
AC_FAILS=()

usage() { sed -n '/^# Usage:/,/^set -euo/p' "$AC_SELF" | sed '$d; s/^# \{0,1\}//' >&2; exit 2; }
ac::fail() { AC_FAILS+=("$1"); log::error "FAIL $1"; }
ac::id() { local id="$1" n=1; while [[ -e "$EVIDENCE_DIR/$id.json" ]]; do n=$((n + 1)); id="${1}-${n}"; done; printf '%s' "$id"; }
ac::k() { lab::kubectl "$@"; }

ac::neg() {
  local chk="$1" what="$2" rc=0; shift 3
  evidence_negative_control "$chk" -- "$@" >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) log::info "negative control $chk failed as it must: $what" ;;
    4) log::error "negative control $chk PASSED ($what): the check is defective"; return 3 ;;
    *) log::error "negative control $chk could not be recorded (exit $rc): $what"; return 3 ;;
  esac
}
ac::chk() {
  local chk="$1" what="$2" id; id="$(ac::id "$3")"; shift 4
  if evidence_run "$id" --check "$chk" --readiness --records SC-015 -- "$@" >/dev/null 2>&1; then log::info "PASS $what"
  else ac::fail "$what [evidence $id]"; grep '^CHECK ' "$EVIDENCE_DIR/$id.stdout" 2>/dev/null | tail -2 | sed 's/^/    | /' >&2 || true; fi
}

# ac::manifest <ns> <stage> <type> <node> <port> <vlan|""> — the standalone candidate
ac::manifest() {
  local vlan=""; [[ -n "$6" ]] && vlan=", vlan: $6"
  cat <<EOF
# T114 binding-conflict candidate (tests/integration/acl_conflict.sh): never persisted
apiVersion: fabric.agentic-netops.io/v1alpha1
kind: Network
metadata:
  name: ${AC_CANDIDATE}
  namespace: $1
spec:
  description: a second $2 $3 access list on $4 $5${6:+.$6} for another tenant
  accessLists:
  - name: ${AC_CANDIDATE}-$2
    stage: $2
    type: $3
    rules:
    - {name: deny-telnet, priority: 10, action: deny, protocol: tcp, destinationPort: "23"}
  attachments:
  - {node: $4, attachment: $5${vlan}}
EOF
}

main() {
  [[ $# -le 1 ]] || usage
  local ref="${1:-agentic-netops-services/lab-acl}"
  [[ "$ref" == -* ]] && usage
  [[ "$ref" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?/[a-z0-9]([-.a-z0-9]*[a-z0-9])?$ ]] || usage
  local ns="${ref%%/*}" holder="${ref#*/}"
  evidence::ensure_dir || return 3
  log::phase ACLConflict

  local id hj key
  id="$(ac::id "AC.holder.${holder}")"
  hj="$(evidence_run "$id" -- ac::k -n "$ns" get "$ACL_NET_RES" "$holder" -o json 2>/dev/null)" \
    || { log::error "holder $ref is not readable [evidence $id]"; return 3; }
  key="$(jq -r '(.spec.accessLists // [])[0] as $l | (.spec.attachments // [])[0] as $a
    | if $l == null or $a == null then "" else "\($l.stage) \($l.type) \($a.node) \($a.attachment) \($a.vlan // "")" end' <<<"$hj")"
  [[ -n "$key" ]] || { log::error "holder $ref carries no access list with an attachment"; return 3; }
  local stage typ node port vlan other
  read -r stage typ node port vlan <<<"$key"
  other=ipv6; [[ "$typ" == ipv6 ]] && other=ipv4
  log::info "holder $ref binds ($node, $port, ${vlan:-0}, $stage, $typ); candidate $ns/$AC_CANDIDATE asks for the same key"
  if ac::k -n "$ns" get "$ACL_NET_RES" "$AC_CANDIDATE" -o name >/dev/null 2>&1; then
    log::error "REFUSED: $ns/$AC_CANDIDATE already exists — delete it explicitly first"; return 3
  fi

  local dir="$EVIDENCE_DIR/acl-conflict"; mkdir -p "$dir"
  ac::manifest "$ns" "$stage" "$typ" "$node" "$port" "$vlan" >"$dir/conflict.yaml"
  ac::manifest "$ns" "$stage" "$other" "$node" "$port" "$vlan" >"$dir/other-family.yaml"

  ac::neg AC-refused "the other-family candidate (a different key) is admitted" -- \
    env ACL_DRY_RUN=1 bash "$AC_LIB" refused "$dir/other-family.yaml" "$ns" "$AC_CANDIDATE" "$ref" || return 3
  ac::neg AC-accepted "the conflicting candidate is refused" -- bash "$AC_LIB" accepted "$dir/conflict.yaml" || return 3

  local before after
  before="$(evidence_run "$(ac::id AC.networks.before)" -- ac::k -n "$ns" get "$ACL_NET_RES" -o name 2>/dev/null)" || before="<unreadable>"
  ac::chk AC-refused "$ns/$AC_CANDIDATE on ($node, $port, ${vlan:-0}, $stage, $typ) refused naming Network $ref; no object created" \
    AC.refused -- bash "$AC_LIB" refused "$dir/conflict.yaml" "$ns" "$AC_CANDIDATE" "$ref"
  after="$(evidence_run "$(ac::id AC.networks.after)" -- ac::k -n "$ns" get "$ACL_NET_RES" -o name 2>/dev/null)" || after="<unreadable>"
  if [[ "$before" == "$after" && "$before" != "<unreadable>" ]]; then log::info "PASS the Networks of $ns are unchanged ($(grep -c . <<<"$after") objects)"
  else ac::fail "the Networks of $ns changed across the refused create: before [$(tr '\n' ' ' <<<"$before")] after [$(tr '\n' ' ' <<<"$after")]"; fi
  ac::chk AC-accepted "the same candidate in $other (a different key) is admitted (server dry-run)" \
    AC.accepted -- bash "$AC_LIB" accepted "$dir/other-family.yaml"

  if [[ ${#AC_FAILS[@]} -gt 0 ]]; then log::error "acl conflict FAILED: ${AC_FAILS[*]}"; return 1; fi
  log::info "acl conflict passed (evidence: $EVIDENCE_DIR)"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
