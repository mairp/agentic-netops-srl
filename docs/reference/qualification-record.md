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

## What is left unqualified (T155, CR-007, 2026-09-25)

What the evidence does not qualify on this lab, recorded so that nothing is assumed in a
requirement's favour. Nothing here is waived: each entry says what is refused or not claimed
because of it, and what would qualify it. The research Open items are
`specs/004-agentic-netops-composite/research.md` §Open items carried to P0; the decisions are in
`docs/decisions/live-findings.md` and listed for review in `docs/decisions/ad-82-review.md`.

| What | State | Effect on the platform | Evidence | What would qualify it |
| --- | --- | --- | --- | --- |
| `acl.egress` — an egress access list | **unqualified**, published through the override annotations (AD-82 `2026-09-24-acl-egress-unqualified`) | An egress request is refused by name at interpretation (FR-097); the enforcement probe skips egress, saying why; `acl` stays qualified (gated property) | `.evidence/agentic-netops_agentic-netops-fabric/20260924T150500Z-p8/AP.ready.acl-probe-egress.stdout` (`887bd93d9c31de27aca263a05c21be0b49340a5f6dd61ea95c95bf60a91bf622`); the published override `.evidence/agentic-netops_agentic-netops-fabric/20260924T154200Z-p8a/AP.qualification.stdout` (`badc8ba6607f21ad243674c51cef70d9a8886474074f7b70fd08661f306bd291`); G9 passed egress device-direct only, `.evidence/agentic-netops_agentic-netops-fabric/20260924T092909Z/gate/items/G9.json` (`325093e3ddae20d4032ff9b3288916a01041c1793b8d170f872520697a7a04b1`) | A data-server re-pin whose layer accepts the egress binding's `must` (the T185 path), then a gate republish, which overwrites the override |
| The host `ping` used by G6's sized probes and `tests/integration/traffic.sh` | **not pinned** — iputils (20240905 when observed) is absent from `versions.lock.yaml` `hostTooling` (NFR-003, AD-21) | G6's payload boundary (9320 / 9300, one byte more failing) was observed with an unpinned host tool; a tool error is never a verdict. **Open, for the operator** (AD-82 `2026-09-21-gate-host-ping`) | `.evidence/agentic-netops_agentic-netops-fabric/20260924T092909Z/gate/items/G6.json` (`1635e4de65349cb3e4b13b9ee6b3d70636480cb51c4533c44b4ca946d92c68f4`) | The operator's decision: pin it through `resolve_pins.sh --host-tooling`, or say otherwise |
| Managed-path deviation visibility and `OVERRULED` under `revertive: true` (Open item 18, G13; AD-48, AD-55) | **not demonstrated live** — on `data-server v0.0.72` drift is restored with no `Deviation` visible first, and no `OVERRULED` can be produced | SC-007's live drift check asserts the restoration only; the deviation and `OVERRULED` are reported as not demonstrated live; `OVERRULED` is covered by envtest (`TestNetworkOverruledPathIsTerminal`) | `.evidence/agentic-netops_agentic-netops-fabric/20260924T092909Z/gate/items/G13.json` (`f802f9df10f43b8372823430128b1317484f88af0a3c3130b40372562b905bd6`); `tests/gate/observed/deviation.json` (`c3ae0a95d0579061df1a3bf57f1c59c242f5adc515f648773ca4a42172e28ca4`) (`answer: restored-without-visible-deviation`) | A data-server release under which a managed-path deviation is observed before its restoration, recorded by G13 |
| Mutual TLS on the agent transport (Open item 13) | **not available** — `slim:0.6.1` accepts a server certificate but exposes no client-certificate verification | R-14's fallback: server-side TLS, the gateway password and NetworkPolicy; mTLS is not claimed | `.evidence/agentic-netops_agentic-netops-fabric/20260924T092909Z/gate/qualifications/slim_tls_keys.json` (`65ec54c2032d05498667488b37b0aeaed6eb6856355985db6d7c27fd88e69bd9`) | A transport gateway release that verifies client certificates, qualified by T166 |
| Offline validation of the goldens as frozen (Open item 21, AD-81) | **not qualified** — `sdc-lite v0.4.0` refuses RFC 7951 identityrefs inside a `must` | `make verify-render-schema` validates a prefix-normalised copy (defect named, wrong-identity negative control); the layer's own validation before every `Set` sees the true form | research.md Open item 21 | An `sdc-lite` release that validates the goldens unmodified; the normalisation is then removed |
| `interface-ref` derived from the `interface-id` key (Open item 3) | **observed 2026-09-28 — not derived**: a binding committed without it carries none in running and has no state at all | None needed: the platform always writes `interface-ref` (FR-037, AD-68) — now shown to be required, not merely safe | `.evidence/agentic-netops_agentic-netops-fabric/20260929T140000Z-p15-t155-probe/OI.i3.cfg.json` (`d8062d82456caadb6806bc118ad97650602a0c3a68fbc737278e52d0f47a2c40`), `OI.i3.state.json` (`cf16edc3736417735ebbe5e44c558365211fd258dfad58511ee01f813a5db7a1`) | — (closed; research.md Open item 3) |
| Which `fib-table` augment a containerised node populates (Open item 8) | **observed 2026-09-28 — both**: the linecard forwarding-complex and the control forwarding-plane `fib-table` are populated on a leaf carrying seven services (the access-list half observed by G9) | None: no read-back reads either `fib-table` path; either may be read | `.evidence/agentic-netops_agentic-netops-fabric/20260929T140000Z-p15-t155-probe/OI.i8.linecard.json` (`c5196eb51000644b7571f5e3ba08554f06403bd4a8c3c260f04452348daa1ad1`), `OI.i8.control.json` (`786978638dbab119ded7d06fbebafd4630d8345f0624670faacea2f05e1dd59d`) | — (closed; research.md Open item 8) |
| An untagged subinterface beside tagged ones on one port (Open item 17) | **observed 2026-09-28 — the device accepts the mix**; the **platform does not offer it** | The mix **stays refused** by the platform's own rule (FR-034, AD-20) — a platform decision, not a device limit; relaxing it would be a recorded requirement change for the operator, not made here (CR-007) | `.evidence/agentic-netops_agentic-netops-fabric/20260929T140000Z-p15-t155-probe/OI.i17.commit.json` (`a41eac91e457027eb27f100f77a60b2e74a257e330ea24b0fb05c9e41cbed53d`), `OI.i17.cfg.tagged.json` (`144084fa52ad1f26d5dc836757ed9755d6f6c7d491b43f1e7cc1618f5489a7c3`) | An operator decision to amend FR-034 (docs/decisions/ad-82-review.md) |
| The layer's dry-run on enumerations and union-typed leaves (AD-82 `2026-09-21-g10-liveness`) | seen weaker than the device on `v0.0.66`; **not re-observed on `v0.0.72`** | Such a value is still refused by the device at commit, so its refusal comes later; G10's liveness case is `port mtu 10000` | `.evidence/agentic-netops_agentic-netops-fabric/20260924T092909Z/G10.liveness.stdout` (`de59b159eb325ad11e14af5370b6e694c9a1a62e46aefc3cad60b8826525cfd0`) | A G10 case on an enumeration and a union-typed leaf, refused by the pinned layer's dry-run |
