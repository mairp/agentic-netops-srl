# Evidence annex — SR Linux retarget research (2026-09-20)

Six research reports produced for the retarget of this composite from SONiC to Nokia SR Linux.
They are **evidence, not specification**: every factual claim in them is tagged `[VERIFIED: source]`
(read or measured in the research session) or `[UNVERIFIED]`. Where a report's *recommendation*
differs from what the specification adopted, **the specification wins**; the adopted decisions are
recorded as RD-01…RD-15 in [../research.md](../research.md) and row by row in
[../platform-coupling.md](../platform-coupling.md).

| File | Topic | Notes |
|---|---|---|
| `01-lab-platform.md` | SR Linux on containerlab: image, types, interfaces, management plane, MTU, capability gate | Throwaway labs were deployed on 26.7.2 and destroyed; the pin is 25.7.1, so every measured number is re-observed at P0 before it is relied on |
| `02-evpn-constructs.md` | EVPN/VXLAN config and state model; how the four constructs render; read-back paths; claim profiles | YANG citations at tag `v25.7.1` |
| `03-acl.md` | ACL model (≥24.3 form), binding point, sequence-id ordering, per-filter verification | Recommends rank-based sequence-ids; the specification adopts the identity mapping instead (RD-05) |
| `04-srv6.md` | SRv6 on SR Linux: not available on any licence-free container type | Recommends a fail-closed gate; the specification defers SRv6 to a future feature instead (RD-04, operator decision) |
| `05-kubenet-sdc-kuid.md` | Kubenet / KUID / SDC state; southbound and provider ownership | Recommends keeping the kuidapps CRDs; the specification adopts a first-party fabric API instead (RD-03, operator decision) |
| `06-telemetry-visualization.md` | gNMIc OTLP output, native telemetry paths, topology visualization, deny-list boundary | Paths were generated at YANG `v25.10.3`; they are re-validated at `v25.7.1` in P0 |

Paths inside the reports that point at a scratch directory (`/tmp/...`) refer to shallow clones made
during the session and are not preserved; the upstream URL and tag/commit cited beside each one is
the durable reference.
