# The fabric qualification record

`agentic-netops-system/fabric-qualification` is the per-construct, per-property result of the
capability gate (FR-097, C-21). It is the **source of truth** every consumer reads: the tier phase of
provisioning copies it into `agentic-netops-agents`, where it is mounted read-only into the mapper,
the allocator and the deployer (no RBAC grant is added for it), and the provider's admission check
refuses a construct or a gated property it does not show as qualified (`Unqualified`).

It is written by `tests/gate/publish_qualification.sh` from the gate record
(`$EVIDENCE_DIR/gate-record.json`, written by `tests/gate/run_gate.sh`), **whether or not the intent
tier is installed** — when `agentic-netops-system` does not exist yet, the publisher creates it with
the ownership label. It is applied with `kubectl apply --server-side` under the field manager
`agentic-netops-gate`, and the apply is run-captured evidence with the manifest attached.

```bash
kubectl -n agentic-netops-system get configmap fabric-qualification -o yaml
kubectl -n agentic-netops-system get configmap fabric-qualification \
  -o jsonpath='{.data.qualification\.json}' | jq .
```

## Shape

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: fabric-qualification
  namespace: agentic-netops-system
  labels:
    app.kubernetes.io/part-of: agentic-netops
    app.kubernetes.io/component: qualification-record
    agentic-netops.io/owned-by: <cluster>
  annotations:
    agentic-netops.io/gate-result: pass | fail
    agentic-netops.io/gate-record-sha256: <sha256 of gate-record.json>
    agentic-netops.io/device-image-digest: sha256:…
    agentic-netops.io/schema: agentic-netops.fabric-qualification/v1
data:
  # one key per construct and one per property: "qualified" | "unqualified"
  vlan: qualified
  vlan.bridged-subinterface: qualified
  mac-vrf: qualified
  mac-vrf.evpn-type2: qualified
  mac-vrf.evpn-type3: qualified
  mac-vrf.reflection: qualified
  mac-vrf.tenant-mtu: qualified
  mac-vrf.anycast-gateway-ipv4: qualified
  mac-vrf.anycast-gateway-ipv6: qualified      # gated
  ip-vrf: qualified
  ip-vrf.evpn-type5-ipv4: qualified
  ip-vrf.evpn-type5-ipv6: qualified            # gated
  ip-vrf.tenant-mtu: qualified
  acl: qualified
  acl.ingress-ipv4: qualified
  acl.ingress-ipv6: qualified
  acl.binding-without-filter: qualified
  acl.per-entry-statistics: qualified
  acl.egress: unqualified                      # gated
  platform.commit-confirmed: qualified
  platform.telemetry-series: qualified
  platform.drift-observability: qualified
  platform.allocation-claims: qualified
  platform.serialization: qualified
  qualification.json: '{ … the full document below … }'
```

The flat keys are what a consumer checks (`<construct>` and `<construct>.<property>`); the values
are exactly `qualified` or `unqualified`. A key that is absent is **unqualified** — a consumer never
assumes a property the record does not state.

## `qualification.json`

| Field | Meaning |
|---|---|
| `schema` | `agentic-netops.fabric-qualification/v1` |
| `gate.result` | the gate's overall result (`pass` / `fail`) |
| `gate.finished_utc`, `gate.evidence_dir`, `gate.failed_items`, `gate.device_image_digest` | where and on what the result was observed |
| `cluster`, `lab` | the cluster and containerlab lab identity |
| `items` | `G1`…`G13` → `pass` / `fail` |
| `constructs.<c>.required_items` | the gate items the construct requires |
| `constructs.<c>.qualified` | every required item passed **and** every non-gated property is qualified |
| `constructs.<c>.properties.<p>.qualified` | the property's own result |
| `constructs.<c>.properties.<p>.gated` | `true` for a gated property: published on its own, refused by name when unqualified, while the construct stays qualified |
| `constructs.<c>.properties.<p>.items`, `.evidence` | the gate item(s) and what they observed |
| `platform.<p>` | platform-level results that gate no single construct: `commit-confirmed` (G5), `telemetry-series` (G7, with the tracked file), `drift-observability` (G13, with its `answer` and the tracked file), `allocation-claims` (G11), `serialization` (G12) |
| `qualifications` | the three P0 qualifications (T166): `vap_served` (with `served`), `slim_tls_keys` (with `client_certificate_verification_exposed` and the `accepted_key_names`), `otlp_shape` — each with its `status` |

## From gate items to constructs

Stated once, in `tests/gate/publish_qualification.sh`:

| Construct | Required items | Properties (gated in bold) |
|---|---|---|
| every construct (base) | G1 G2 G3 G4 G10 G11 G12 | — |
| `vlan` | base | `bridged-subinterface` (G3) |
| `mac-vrf` | base, G6, G8 | `evpn-type2`, `evpn-type3`, `reflection` (G8), `tenant-mtu` (G6), `anycast-gateway-ipv4` (G8), **`anycast-gateway-ipv6`** (G8) |
| `ip-vrf` | base, G6, G8 | `evpn-type5-ipv4` (G8), **`evpn-type5-ipv6`** (G8), `tenant-mtu` (G6) |
| `acl` | base, G9 | `ingress-ipv4`, `ingress-ipv6`, `binding-without-filter` (G9), `per-entry-statistics` (G3), **`egress`** (G9) |

The gated properties are the ones the specification names as qualifications a construct can lack
without the construct itself being refused: an egress access list (`stage: egress`), an IPv6
anycast gateway and an IPv6 Type-5 route. In the gate they are the checks named `property:…` in the
item records (`g08_evpn.sh`, `g09_acl.sh`); every other check of an item is required.

A failed item is never skipped or weakened: it is recorded, the constructs and properties it gates
are published `unqualified`, and they are refused by name at interpretation until a later gate run
qualifies them.
