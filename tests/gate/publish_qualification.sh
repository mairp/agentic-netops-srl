#!/usr/bin/env bash
# tests/gate/publish_qualification.sh — publish the per-construct, per-property qualification record
# (T046; FR-097, C-21; quickstart.md §1 "Where the gate writes its evidence";
# docs/reference/qualification-record.md is the schema).
#
# Reads the capability gate's record ($EVIDENCE_DIR/gate-record.json, written by run_gate.sh) and
# writes ConfigMap agentic-netops-system/fabric-qualification — the source of truth the intent tier's
# copy is made from — WHETHER OR NOT THE TIER IS INSTALLED: when the namespace does not exist yet it
# is created (labelled with the ownership label); the tier phase later copies the ConfigMap into
# agentic-netops-agents. Applied with `kubectl apply --server-side` under the field manager
# agentic-netops-gate, run-captured with evidence_run, the manifest attached to the record.
#
# The mapping from gate items to constructs and properties is stated once, here (and documented in
# docs/reference/qualification-record.md):
#   base (every construct)  G1 G2 G3 G4 G10 G11 G12 passed
#   vlan                    base; bridged-subinterface (G3)
#   mac-vrf                 base, G6, G8; evpn-type2, evpn-type3, reflection, tenant-mtu,
#                           anycast-gateway-ipv4; GATED: anycast-gateway-ipv6
#   ip-vrf                  base, G6, G8; evpn-type5-ipv4; GATED: evpn-type5-ipv6
#   acl                     base, G9; ingress-ipv4, ingress-ipv6, binding-without-filter,
#                           per-entry-statistics (G3); GATED: egress
# A construct is qualified when its required items passed; a GATED property is published on its own
# and an unqualified one is refused by name at interpretation (FR-097) while the construct stays
# qualified. A property the gate did not observe is unqualified — never assumed.
#
# Usage: publish_qualification.sh [--record <gate-record.json>] [--dry-run] [--output <file>]
#   --dry-run   build and print the ConfigMap, apply nothing (no cluster needed)
# Environment: EVIDENCE_DIR, CLUSTER_NAME, KUBECTL, KUBE_CONTEXT.
set -euo pipefail

PQ_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/lab.sh
source "$PQ_ROOT/tests/lib/lab.sh"
# shellcheck source=../../scripts/lib/log.sh
source "$PQ_ROOT/scripts/lib/log.sh"

PQ_NAMESPACE="agentic-netops-system"
PQ_NAME="fabric-qualification"
PQ_FIELD_MANAGER="agentic-netops-gate"

record="${EVIDENCE_DIR:+$EVIDENCE_DIR/gate-record.json}"; dry=0; output=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --record) record="${2:?--record needs a file}"; shift 2 ;;
    --dry-run) dry=1; shift ;;
    --output) output="${2:?--output needs a file}"; shift 2 ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) echo "publish_qualification: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
[[ -n "$record" && -f "$record" ]] || { echo "publish_qualification: no gate record (${record:-unset}); run tests/gate/run_gate.sh first" >&2; exit 2; }
jq -e '.schema == "agentic-netops.gate-record/v1"' "$record" >/dev/null 2>&1 || { echo "publish_qualification: $record is not a gate record" >&2; exit 2; }

# pq::qualification <gate-record> — the qualification document (JSON)
pq::qualification() {
  jq -S --arg cluster "$CLUSTER_NAME" '
    .items as $it
    | def passed(i): (($it[i].status // "absent") == "pass");
      def checks(i; re): [($it[i].checks // [])[] | select(.name | test(re))];
      def allpass(i; re): (checks(i; re) | length > 0 and all(.status == "pass"));
      def prop(q; items; evidence): {qualified: q, items: items, evidence: evidence};
      (["G1","G2","G3","G4","G10","G11","G12"]) as $base
    | ($base | all(passed(.))) as $b
    | {
        "vlan": {
          required_items: $base,
          properties: {
            "bridged-subinterface": prop(passed("G3"); ["G3"]; "the bridged feature on every device")
          }
        },
        "mac-vrf": {
          required_items: ($base + ["G6","G8"]),
          properties: {
            "evpn-type2": prop(passed("G8") and allpass("G8"; "^type2:"); ["G8"]; "Type-2 received through a reflecting spine, each way"),
            "evpn-type3": prop(passed("G8") and allpass("G8"; "^type3:"); ["G8"]; "Type-3 received through a reflecting spine, each way"),
            "reflection": prop(passed("G8") and allpass("G8"; "^reflector-settings:"); ["G8"]; "inter-as-vpn + route-reflector client on the reflectors, shown necessary by the negative control"),
            "tenant-mtu": prop(passed("G6"); ["G6"]; "9412/9398/9348 and the 9320/9300 payload boundary"),
            "anycast-gateway-ipv4": prop(passed("G8") and allpass("G8"; "^anycast-gateway-ipv4$"); ["G8"]; "IPv4 anycast gateway reached across the fabric"),
            "anycast-gateway-ipv6": (prop(passed("G8") and allpass("G8"; "^property:anycast-gateway-ipv6$"); ["G8"]; "IPv6 anycast gateway reached end to end") + {gated: true})
          }
        },
        "ip-vrf": {
          required_items: ($base + ["G6","G8"]),
          properties: {
            "evpn-type5-ipv4": prop(passed("G8") and allpass("G8"; "^type5-ipv4"); ["G8"]; "IPv4 Type-5 received through a reflecting spine, installed, routed end to end"),
            "evpn-type5-ipv6": (prop(passed("G8") and allpass("G8"; "^property:ipv6-type5"); ["G8"]; "IPv6 Type-5 received through a reflecting spine, installed, routed end to end") + {gated: true}),
            "tenant-mtu": prop(passed("G6"); ["G6"]; "9412/9398/9348 and the 9320/9300 payload boundary")
          }
        },
        "acl": {
          required_items: ($base + ["G9"]),
          properties: {
            "ingress-ipv4": prop(passed("G9") and allpass("G9"; "^ingress-ipv4-applied$"); ["G9"]; "keyed applied-side read-back on input"),
            "ingress-ipv6": prop(passed("G9") and allpass("G9"; "^ingress-ipv6-applied$"); ["G9"]; "keyed applied-side read-back on input"),
            "binding-without-filter": prop(passed("G9") and allpass("G9"; "^binding-without-filter-accepted$"); ["G9"]; "a binding entry with interface-ref and no filter is accepted (AD-68)"),
            "per-entry-statistics": prop(passed("G3"); ["G3"]; "acl-subinterface-entry-statistics advertised"),
            "egress": (prop(passed("G9") and allpass("G9"; "^property:egress-acl$"); ["G9"]; "output binding programmed on output only") + {gated: true})
          }
        }
      } as $c
    | ($c | with_entries(.value.qualified = (
          (.value.required_items | all(passed(.)))
          and ([.value.properties[] | select((.gated // false) | not) | .qualified] | all)))) as $constructs
    | {schema: "agentic-netops.fabric-qualification/v1",
       gate: {result: .result, finished_utc: .finished_utc, evidence_dir: .evidence_dir,
              failed_items: .failed_items, device_image_digest: .device_image_digest},
       cluster: $cluster, lab: .lab,
       items: ($it | with_entries(.value = .value.status)),
       constructs: $constructs,
       platform: {
         "commit-confirmed": {qualified: passed("G5"), items: ["G5"]},
         "telemetry-series": {qualified: passed("G7"), items: ["G7"], file: "tests/gate/observed/telemetry-series.json"},
         "drift-observability": {qualified: passed("G13"), items: ["G13"],
                                 answer: ($it.G13.observations.answer // null), file: "tests/gate/observed/deviation.json"},
         "allocation-claims": {qualified: passed("G11"), items: ["G11"]},
         "serialization": {qualified: passed("G12"), items: ["G12"], file: "tests/gate/observed/serialization.json"}
       },
       qualifications: (.qualifications // {} | with_entries(.value = {status: .value.status}
                        + (if .key == "vap_served" then {served: .value.served} else {} end)
                        + (if .key == "slim_tls_keys" then {client_certificate_verification_exposed: .value.client_certificate_verification_exposed, accepted_key_names: .value.accepted_key_names} else {} end)))
      }' "$1"
}

# pq::configmap <qualification.json> <record-sha256> — the ConfigMap (JSON)
pq::configmap() {
  jq -S --arg ns "$PQ_NAMESPACE" --arg name "$PQ_NAME" --arg cluster "$CLUSTER_NAME" --arg sha "$2" '
    . as $q
    | ([.constructs | to_entries[] | {key: .key, value: (if .value.qualified then "qualified" else "unqualified" end)}]
       + [.constructs | to_entries[] | .key as $c | .value.properties | to_entries[]
          | {key: "\($c).\(.key)", value: (if .value.qualified then "qualified" else "unqualified" end)}]
       + [.platform | to_entries[] | {key: "platform.\(.key)", value: (if .value.qualified then "qualified" else "unqualified" end)}]
      ) | from_entries
    | {apiVersion: "v1", kind: "ConfigMap",
       metadata: {name: $name, namespace: $ns,
                  labels: {"app.kubernetes.io/part-of": "agentic-netops", "app.kubernetes.io/component": "qualification-record",
                           "agentic-netops.io/owned-by": $cluster},
                  annotations: {"agentic-netops.io/gate-result": $q.gate.result,
                                "agentic-netops.io/gate-record-sha256": $sha,
                                "agentic-netops.io/device-image-digest": ($q.gate.device_image_digest // ""),
                                "agentic-netops.io/schema": $q.schema}},
       data: (. + {"qualification.json": ($q | tojson)})}' "$1"
}

qual="$(mktemp)"; cm="$(mktemp)"
trap 'rm -f "$qual" "$cm"' EXIT
pq::qualification "$record" >"$qual"
pq::configmap "$qual" "$(sha256sum "$record" | awk '{print $1}')" >"$cm"

if [[ -n "$output" ]]; then cp "$cm" "$output"; fi
if [[ "$dry" == 1 ]]; then cat "$cm"; exit 0; fi

# the run's evidence, when there is one
if [[ -n "${EVIDENCE_DIR:-}" ]]; then
  # shellcheck source=../../scripts/lib/evidence.sh
  source "$PQ_ROOT/scripts/lib/evidence.sh"
  run() { local id="$1"; shift; evidence_run "$id" "$@"; }
  mf="$EVIDENCE_DIR/gate/qualification-configmap.json"
  n=1; while [[ -e "$mf" ]]; do n=$((n + 1)); mf="$EVIDENCE_DIR/gate/qualification-configmap-${n}.json"; done
  mkdir -p "$(dirname "$mf")"; cp "$cm" "$mf"
  att=(--attach "${mf#"$EVIDENCE_DIR"/}")
  sfx="$(date -u +%H%M%S)-${RANDOM}"
else
  run() { shift; [[ "$1" == --attach ]] && shift 2; [[ "$1" == -- ]] && shift; "$@"; }
  mf="$cm"; att=(); sfx=""
fi

if ! lab::kubectl get namespace "$PQ_NAMESPACE" >/dev/null 2>&1; then
  log::info "qualification record: namespace $PQ_NAMESPACE absent — creating it (the record is written whether or not the tier is installed)"
  ns_manifest="$(jq -n --arg ns "$PQ_NAMESPACE" --arg c "$CLUSTER_NAME" \
    '{apiVersion: "v1", kind: "Namespace", metadata: {name: $ns, labels: {"agentic-netops.io/owned-by": $c}}}')"
  nsf="$(mktemp)"; printf '%s\n' "$ns_manifest" >"$nsf"
  run "qualification-namespace${sfx:+-$sfx}" -- lab::kubectl apply --server-side --field-manager "$PQ_FIELD_MANAGER" -f "$nsf" >/dev/null
  rm -f "$nsf"
fi
run "qualification-publish${sfx:+-$sfx}" "${att[@]}" -- lab::kubectl apply --server-side --force-conflicts \
  --field-manager "$PQ_FIELD_MANAGER" -f "$mf" >/dev/null
log::info "qualification record published: $PQ_NAMESPACE/$PQ_NAME ($(jq -r '[.data | to_entries[] | select(.key | test("^[a-z-]+$")) | "\(.key)=\(.value)"] | join(" ")' "$cm"))"
