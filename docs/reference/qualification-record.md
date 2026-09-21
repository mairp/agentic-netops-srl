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

## G11 per allocation authority

G11 — the allocation claim round-trip and the six observations of
`contracts/kuid-claim-profiles.md` §6 — qualifies the **allocation authority**, not the device, so
its result is recorded per authority. Which authority a lab runs is `versions.lock.yaml`
`allocationAuthority.kind`; `platform.allocation-claims` and the `G11` item of a published record
are that run's result against that authority, and `g11-observations.json` names it in
`authority.kind` (see [the allocation authority](../operations/allocation-authority.md)).

| Authority | G11 result | Evidence |
|---|---|---|
| `kuid` — kuid-server v0.0.13 (`*.be.kuid.dev`, `kuid-system`) | **failed**, 2026-09-21 (`utc_time` 2026-09-21T04:31:38Z): the scratch indices of the round trip could not be created, so no claim could be bound; provisioning stopped naming G11 with nothing above the authority installed | run evidence `.evidence/agentic-netops_agentic-netops-fabric/20260921T042659Z/g11-observations.json`; the byte-identical copy the lock cites, `docs/decisions/allocator-substitution/g11-observations.json` (SHA-256 `42050ed2b8638f6ccae418cbb24e6bd2d1660e71b881c389291df2729f5dbc45`) |
| `first-party` — the recorded substitute (`IdentifierPool`/`IdentifierClaim`, `fabric.agentic-netops.io`, `agentic-netops-allocation`) | **passed**, 2026-09-21 (`utc_time` 2026-09-21T10:46:09Z), at `AppsReady` of T052's clean bring-up and carried into that run's gate record: the round trip, the stated-value pair (a) bound exactly and (b) refused naming the holder, (c) lowest free value (`1000, 1001, 1002` on a fresh index), (d) no value below the index minimum, (e) `metadata.labels` selectable with `-l` (negative control: the label held elsewhere is not selected), (f) a deleted claim's value bound again by an immediate second claim; scratch removed and read back | run evidence `.evidence/agentic-netops_agentic-netops-fabric/20260921T104117Z/g11-observations.json` (`authority.kind: first-party`, SHA-256 `7eb13f103aa45df02b96aa2cb5ff3c2668553174d989f2a3076d782781808d67`); every later bring-up of T052 repeats it (see that task's evidence) |

A failing G11 on the substitute stops provisioning exactly as it did on kuid: there is no third
authority, and nothing is published for a run that stopped at G11.

## Data-server re-pin (T185, AD-80)

`data-server v0.0.66` stopped reporting deviations until restarted and never reverted drift under
`revertive: true` (docs/decisions/live-findings.md, finding 6). AD-80 re-pins to the newest release
that fixes both **and** qualifies live with `config-server v0.0.58` unchanged: the lab reaches
`TargetsReady`, and G10 and G13 pass, each through `evidence_run`. Releases were tried newest first,
starting at `v0.0.72`; the first that qualified is the one pinned, so no older one was tried.

| Release | Digest | TargetsReady | G10 | G13 | Result |
|---|---|---|---|---|---|
| `v0.0.72` (commit `de8a8dd7777e13909c1b2c4b2891e764001420d4`) | `sha256:f294c2b3810da2d92c4cba0affede839743e75d9343e4ccc80b38e39bd95dca0` (resolved by `scripts/lib/resolve_pins.sh`) | yes, 2026-09-21T10:00:56Z — all four Targets Ready | **pass** — valid Config accepted by the dry-run, r1–r8 and the liveness case refused, nothing persisted (`.evidence/agentic-netops_agentic-netops-fabric/20260921T100102Z/gate/items/G10.json`, SHA-256 `a7c7bd20ffbccf209490aeedd06ac115c51fb962f42b64f3d18ec4a912318a83`) | **pass** — drift on a gate-owned path restored after 5 s, no `NOT_APPLIED` deviation visible before the restore (`.evidence/agentic-netops_agentic-netops-fabric/20260921T100127Z/gate/items/G13.json`, SHA-256 `200d82e7d6daa979d1dbff33e7541b0ae23e035e0cfa79f48a058befe9022ea2`) | **pinned** in `versions.lock.yaml` part 5 |
| `v0.0.66` (the previous pin) | `sha256:fe138dcfcfeb5bee2a615bd4e9616bafc9d27b57ae55cee9360d4fd0d2cecbf7` | yes | pass | deviation visible, **no restoration in 180 s**; deviation manager could block for good (pass 37) | replaced |

G13 records what it saw and does not fail on either answer (AD-34): on `v0.0.72` the observable
outcome is the **restoration**, not a visible deviation, and `tests/gate/observed/deviation.json`
says so (`answer: restored-without-visible-deviation`). What T064's managed-drift suite may assert
is bounded by that file.
