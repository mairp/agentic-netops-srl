# Contract: the single translation implementation

**Feature**: `004-agentic-netops-composite` | **Carries**: FR-060, FR-065, FR-045 |
**Decision**: D-30, AD-41, AD-56

A thin Go HTTP wrapper over the repository's existing translator package. It exists so the Python
deployer can reach the Go translator **without any translation logic being
reimplemented in Python** (FR-060). It adds no semantics: it calls the same strict-parse →
validate → translate path the existing translator CLI already calls.

**This is the whole of the one-translator rule in practice.** Intent becomes fabric intent here and
nowhere else, and the access-list render is a field on the same object rather than a second path.
A second render — through the device-configuration layer, or in Python, or in a new controller — is
a contract violation, not an optimization.

## Deployment

A **sidecar container in the deployer pod**, bound to `127.0.0.1:8090`. **No Service, no
network-policy allowance, no cluster-visible surface.** The call is always pod-local, so the
translator adds zero attack surface and the namespace policy stays deny-all for cross-pod traffic.

## `POST /v1/translate`

**Request**: a normalized service intent object, or an array of them, matching
[`normalized-service-intent.schema.json`](./normalized-service-intent.schema.json).

**Response `200`** — the emitted object is always `fabric.agentic-netops.io/v1alpha1` `Network`,
one per service:

```json
{ "manifests": [ { "apiVersion": "fabric.agentic-netops.io/v1alpha1", "kind": "Network" } ],
  "yaml": "apiVersion: fabric.agentic-netops.io/v1alpha1\nkind: Network\n…" }
```

What the emitted `spec:` carries, and what it deliberately does not:

| Field | Emitted? |
|---|---|
| `vlans[]`, `bridgeDomains[]`, `routers[]`, `accessLists[]`, `attachments[]` | yes — the five lists the provider renders from |
| `routers[].rd` | **no.** There is no route-distinguisher field anywhere: the device derives the distinguisher itself from the attachment leaf's system address and the EVPN instance identifier, and the platform never renders one (RD-09) |
| `bridgeDomains[].evpn.routeTargets`, `routers[].routeTargets` | yes, as **derived, read-only** values `target:<fabricASN>:<vni>` — carried so the render is explicit rather than left to the device's per-leaf auto-derivation, and so the second confirmation covered them. A request that supplies them is refused |
| `accessLists[].type` | `ipv4` or `ipv6` only; the input spellings `l3`, `l3v6`, `ip` and `ipv6` are folded on entry |
| `accessLists[].stage` | `ingress` or `egress`; `egress` only when the qualification record shows it qualified (FR-097) |
| `accessLists[].rules[].priority` | `1`–`65534`, distinct, emitted **unchanged** as the device's entry sequence number, evaluated ascending with the first match winning; **`65535` is reserved** for the default action |
| `accessLists[].defaultAction` | emitted when declared, as the terminal entry at the reserved position; when absent, the platform owes the operator the statement that unmatched traffic is accepted (FR-041) |
| `attachments[]` | `{node, attachment: ethernet-1/N, vlan?, vrf?}`; an access-list attachment MAY carry `vlan` to name the subinterface, and must resolve to one that already exists — that VLAN is a reference, in either band, and claims nothing (AD-47) |

**Response `422`** — validation rejected, all-or-nothing, nothing partial:

```json
{ "error": "validation",
  "causes": ["input[0]: unsupported feature: traffic-engineering",
             "input[0]: acl.rules[2].priority: 65535 is reserved for the default action; 1-65534 is usable"] }
```

## Rules

- **All-or-nothing.** Validation runs over the whole batch before any output. A single rejection
  fails the request; **no manifest is returned** (FR-045).
- **Deterministic.** Same input, same bytes out, in a stable order — the property the golden files
  depend on.
- **No cluster interaction.** The translator reads and writes JSON and YAML only. Applying is the
  deployer's job, after the dry-run.
- **Unknown fields are rejected**, because the parser rejects them. The Python model must be
  equally strict so the failure lands at the agent boundary rather than here (FR-065).
- **The VLAN check here is structural, and only structural (AD-41).** The translator refuses a VLAN
  outside `100–4000`, stating both bands, and that is all it says about a VLAN's value. Its input is
  the allocator's output, in which a VLAN the operator named and a VLAN the authority allocated are
  the same bare integer — the normalized service intent carries **no provenance field**, and none is
  added — so the translator cannot tell the two apart and is never asked to. The **naming band**,
  `100–999` for a VLAN an operator names, is the **mapper's** rule: it is enforced at
  interpretation, before any claim exists, where a VLAN present is by construction a VLAN that was
  named ([interpretation.schema.json](./interpretation.schema.json),
  [kuid-claim-profiles.md](./kuid-claim-profiles.md) §2 rule 1). An allocated VLAN of `1000–4000`
  therefore passes here, as it must. The VLAN on a standalone `acl`'s attachment is a **reference**
  to a subinterface another service created and is likewise held to the structural range alone
  (AD-47).
- **Canonicalization happens on entry.** A migration alias is folded to its construct before any
  validator or translator sees it, and the arrival vocabulary is recorded as provenance (FR-044,
  FR-046). Nothing downstream ever sees a retired name as a type.

## Equivalence oracle (SC-021)

The migration golden files are the oracle. For each construct and each migration alias, the
agent-produced normalized JSON is posted here and the emitted `spec:` must match the corresponding
golden file **byte for byte**:

| Fixture set | Input | Golden |
|---|---|---|
| Construct — local broadcast domain | `construct_vlan.json` | `construct_vlan.spec.golden.yaml` |
| Construct — extended bridge domain | `construct_macvrf.json` | `construct_macvrf.spec.golden.yaml` |
| Construct — routed instance | `construct_ipvrf.json` | `construct_ipvrf.spec.golden.yaml` |
| Construct — gateway composition | `construct_macvrf_gateway.json` | `construct_macvrf_gateway.spec.golden.yaml` |
| Construct — filter | `construct_acl.json` | `construct_acl.spec.golden.yaml` |
| **Migration alias** — multipoint L2 | `supported_vpls.json` | `supported_vpls.spec.golden.yaml` |
| **Migration alias** — point-to-point L2 | `supported_vpws_optin.json` | `supported_vpws.spec.golden.yaml` |
| **Migration alias** — routed VPN | `supported_l3vpn.json` | `supported_l3vpn.spec.golden.yaml` |
| **Migration alias** — integrated L2/L3 | `supported_irb.json` | `supported_irb.spec.golden.yaml` |

The four migration-alias fixtures are the brownfield vocabulary this path exists to read; their
file names are historical. Each now emits the **construct** as its service type, with the arrival
vocabulary recorded as provenance — which changes every one of those golden files, and is exactly
what the provenance requirement asks for (D-19).

**The equivalence test is between vocabularies, not against a golden alone**: the same service
expressed as a construct and as its migration alias must emit a byte-identical `spec:` block, so an
accidental render change fails even when both golden files moved together (R-27, SC-018).

The rejection fixtures are the negative half, proving the platform refuses rather than partially
assigns: the unsupported-feature set, the malformed-unknown-field set, the collision set, and the
full construct and access-list refusal set enumerated in [quickstart.md](../quickstart.md) §6.
