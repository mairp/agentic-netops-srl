# 05 — The southbound control plane on SR Linux: Kubenet + KUID + SDC

**Topic owner**: research agent 05 · **Date**: 2026-09-20 · **Feature**: `004-agentic-netops-composite` retarget to Nokia SR Linux

**Answers**: [spec.md](../../../../../root/agentic-netops-srl/specs/004-agentic-netops-composite/spec.md) §Open decisions **1** (southbound) and **2** (provider ownership).
**Replaces**: PC-01 (the five-part compatibility set), PC-14 (the OpenConfig-vs-native register), and
`platform-coupling.md` §Recorded divergence.

Every factual claim is tagged `[VERIFIED: <source>]` (read this session) or `[UNVERIFIED: from memory]`.

---

## 0. Executive summary — the three findings that change the decision

**Finding A — the inversion in Open decision 1 is real, but it is not "restore".**
The SONiC build never ran SDC at all. Its `deploy/sdc/seed/*.yaml` declares
`apiVersion: sdc.sdcio.dev/v1alpha1` with `kind: Schema` carrying `spec.image`, `spec.openconfigCommit`,
`spec.nativeCommit`, and `kind: Config` with `spec.type: ConnectionProfile`
[VERIFIED: /root/agentic-netops/deploy/sdc/seed/sonic-schema.yaml]. **None of those exist.** The real sdcio API
groups are `inv.sdcio.dev` and `config.sdcio.dev`
[VERIFIED: sdcio/config-server@0f05e2ef `crds/` — 20 CRD files, all `inv.sdcio.dev_*` or `config.sdcio.dev_*`].
`deploy/sdc/install.sh` fetches CRDs from `https://github.com/sdcio/sdc/...`
[VERIFIED: /root/agentic-netops/deploy/sdc/install.sh]; that repository returns **404**
[VERIFIED: `GET https://api.github.com/repos/sdcio/sdc` → `{"message":"Not Found","status":"404"}`].
`versions.lock.yaml` pins `sdc.core.repo: https://github.com/sdcio/sdc, release: v0.31.0`
[VERIFIED: /root/agentic-netops/versions.lock.yaml] — a pin to a repository that does not exist.
The same holds for Kubenet and KUID: `deploy/kubenet/install.sh` fetches
`kubenet-dev/kubenet/<commit>/config/crd/bases/network.kubenet.dev_networks.yaml` and
`kuidio/kuid/<commit>/config/crd/bases/id.kuid.dev_*.yaml`
[VERIFIED: /root/agentic-netops/deploy/kubenet/install.sh]. The commits exist
[VERIFIED: GitHub API returns both `bae1c487…` (2024-05-28) and `7528e815…` (2024-12-27)] but **neither repository
has a `config/crd/bases` directory**: `kubenet-dev/kubenet` is an artifacts repo with
`topo/ network/ lab/ sdc/ pkg/ inventory/ choreo/ artifacts/` and no Go code
[VERIFIED: shallow clone, full file listing], and `kuidio/kuid` serves its APIs through **aggregated
APIServices**, not CRDs — `artifacts/apiservice-{as,extcomm,genid,infra,ipam,vlan,vxlan}.yaml`
[VERIFIED: kuidio/kuid@be8e5686 `artifacts/`]. The install scripts silently fall back to hand-written
look-alike bundles in `deploy/*/crds/` whose groups are `network.kubenet.dev`, `id.kuid.dev` and
`sdc.sdcio.dev` [VERIFIED: parsed all three bundles] — **none of which is an upstream group.**

So FR-013 ("reuse the pinned upstream APIs … instead of introducing duplicate CRDs") was violated by
*look-alike* CRDs in *look-alike* groups, and the `Network` shape the whole 004 data model rests on
(`spec.vlans[]`, `spec.bridgeDomains[].irb`, `spec.routers[].l3vni`, `spec.accessLists[]`,
`spec.attachments[]`) is a **first-party invention**, not an upstream API
[VERIFIED: /root/agentic-netops/pkg/kubenet/network.go, whose own comment claims "the CRD schema (pinned
upstream) remains the single source of truth"; and /root/agentic-netops/deploy/kubenet/crds/kubenet-crds.yaml,
where `networks.network.kubenet.dev` `spec` is `{type: object, x-kubernetes-preserve-unknown-fields: true}` —
i.e. no schema at all].

The consequence for the retarget: choosing `provider → SDC Config → gNMI → SR Linux` is **not a restoration
of something that regressed. It is the first time any of it is implemented.** But it is also cheaper than
the SONiC path was, because on SR Linux every piece already exists and is exercised in upstream CI.

**Finding B — SDC is alive and SR Linux is its reference target; Kubenet and KUID are dormant.**

| Project | HEAD (shallow clone) | last push | latest release | verdict |
|---|---|---|---|---|
| `sdcio/config-server` | `0f05e2ef` 2026-08-20 | **2026-09-18** | **v0.0.58** (2026-08-19) | **active** |
| `sdcio/data-server` | `efcdd7bd` 2026-09-08 | 2026-09-15 | v0.0.72 (2026-08-19) | active |
| `sdcio/schema-server` | — | 2026-09-16 | v0.0.34 (2026-01-15) | active |
| `sdcio/integration-tests` | 2026-09-07 | 2026-09-14 | — | active, **runs against SR Linux 25.7.1** |
| `sdcio/docs` | 2026-09-10 | 2026-09-10 | — | active |
| `sdcio/srlinux-yang-patch` | `2c7703b1` 2025-01-08 (main) | 2025-07-28 | — | branches `v24.7 v24.10 v25.3 v25.7` only |
| `kubenet-dev/kubenet` | `9c91bb81` 2024-11-18 | 2024-11-18 | **no releases** | **dormant ~22 months** |
| `kubenet-dev/apis` | `d5605a09` 2024-12-26 | 2024-12-26 | — | dormant |
| `kubenet-dev/kubenetctl` | — | 2024-12-05 | v0.0.4 (2024-07-04) | dormant |
| `kubenet-dev/kubenet-choreo` | 2024-12-13 | 2024-12-13 | — | abandoned experiment |
| `kubenet-dev/docs` | `1b36f727` **2025-11-12** | 2025-11-12 | — | docs only ("add-sdc-talk") |
| `kuidio/kuid` | `be8e5686` 2024-12-27 | 2025-02-17 | v0.0.13 (2024-12-27) | dormant |
| `kuidio/kuidapps` | `0c1a0b2e` 2024-11-24 | 2024-11-24 | v0.0.33 (2024-06-12) | dormant |
| `kuidio/nokia-srl` | `f6b92141` 2024-06-11 | 2024-08-19 | v0.0.15 (2024-06-11) | dormant |

[VERIFIED: `GET https://api.github.com/orgs/{sdcio,kubenet-dev,kuidio}/repos` and
`/releases`; shallow clones of each repo, `git log -1`.]

**Finding C — `accessLists` does not exist upstream, and neither does the anycast gateway, nor a local-only
VLAN.** The upstream `Network` is `network.app.kuid.dev/v1alpha1` with exactly two service lists
[VERIFIED: kuidio/kuidapps@0c1a0b2e `apis/network/v1alpha1/network_types.go`]:

```go
type NetworkSpec struct {
    Topology string
    Bridges  []*NetworkBridge  // name, networkID, interfaces[]
    Routers  []*NetworkRouter  // name, networkID, interfaces[]
}
type NetworkInterface struct {
    Bridge *string; EndPoint *string; *infrabev1alpha1.NodeID
    Addresses []*NetworkInterfaceAddress; VLANID *uint32
    Selector *metav1.LabelSelector; VLANTagging bool
    Protocols *NetworkInterfaceProtocols  // bgp{localAS,peerAS}
}
```

(The published `v0.0.1` artifacts still spell these `bridgeDomains` / `routingTables`
[VERIFIED: kubenet-dev/kubenet `network/vpc{1,2,3}-*.yaml`] — the field names were renamed between the
tutorial artifacts and the kuidapps main branch. This is the "tutorial YAML vs main branch" hazard D-04
already names, and it is real.)

There is **no** `vlans`, **no** `accessLists`, **no** explicit `rd`/`routeTargets`, **no** `l2vni`/`l3vni`,
**no** `irb` sub-object, and no anycast-gateway field anywhere in the type.

---

## 1. Kubenet: current state, what it installs, its CRDs

### 1.1 It is not one project; it is a bundle of four

`kubenet-dev/kubenet` is an **artifacts-only repo**. Its `makefile` runs
`knetctl release artifacts/kubenet-release.yaml artifacts/out` [VERIFIED: kubenet `makefile`], and
`artifacts/kubenet-release.yaml` is the whole installation [VERIFIED, quoted verbatim]:

```yaml
release: v0.0.1
apps:
- name: kuid-server   url: …/kuidio/kuid/latest/artifacts/out/artifacts.yaml
  image: ghcr.io/kuidio/kuid-server:latest    version: v0.0.7
- name: kuidapps      url: …/kuidio/kuidapps/latest/artifacts/out/artifacts.yaml
  image: ghcr.io/kuidio/kuidapps:latest       version: v0.0.33
- name: kuid-nokia-srl url: …/kuidio/nokia-srl/latest/artifacts/out/artifacts.yaml
  image: ghcr.io/kuidio/nokia-srl:latest      version: v0.0.15
- name: pkgserver     url: …/pkgserver-dev/pkgserver/latest/artifacts/out/artifacts.yaml
  image: ghcr.io/pkgserver-dev/pkgserver:latest version: v0.0.4
#- name: sdc   url: https://docs.sdcio.dev/artifacts/basic-usage/colocated.yaml   ← commented out
```

Read that last line carefully: **SDC is commented out of the Kubenet release bundle.** Kubenet's own
installer does not install SDC; the operator installs it separately from `docs.sdcio.dev`. So "Kubenet
installs SDC" is false; Kubenet *emits* `config.sdcio.dev/v1alpha1 Config` objects and expects SDC to be
present.

Also note every `image:` is `:latest` with the real version in a sibling `version:` field — the bundle is
**not** digest-pinned and not even tag-pinned. NFR-003 cannot be satisfied by consuming it as published.

### 1.2 The API surface, by group

| Group / version | Kinds | Source |
|---|---|---|
| `topo.app.kuid.dev/v1alpha1` | `Topology` | kuidapps [VERIFIED: `artifacts/out/kuidapps.yaml` CRD list] |
| `network.app.kuid.dev/v1alpha1` | **`Network`**, **`NetworkDesign`**, **`NetworkDevice`** | kuidapps [VERIFIED: same] |
| `infra.kuid.dev/v1alpha1` | `Node`, `Link`, `Endpoint`, `Module`, `ModuleBay`, `NodeItem`, `Adaptor`, `Port`, `NodeSet`, `LinkSet`, `EndpointSet`, `Cluster`, `Partition` | kuid aggregated APIService [VERIFIED: kuid `artifacts/apiservice-infra.yaml`; `apis/infra/v1alpha1/*_types.go`] |
| `srl.nokia.app.kuid.dev/v1alpha1` | `NodeModel` | kuidio/nokia-srl [VERIFIED: `artifacts/srl.nokia.app.kuid.dev_nodemodels.yaml`] |

Kinds the task asked about that **do not exist**: `NetworkConfig` (it was renamed `NetworkDesign`; the
v0.0.1 artifacts still use `kind: NetworkConfig` under `network.app.kuid.dev`
[VERIFIED: kubenet `network/default-networkconfig.yaml`] while kuidapps main serves `NetworkDesign`
[VERIFIED: kuidapps `apis/network/v1alpha1/networkdesign_types.go`] — the **exact** version skew D-04 warns
about), and `NetworkParam` (there is a `networkparams` *reconciler* in kuidapps
[VERIFIED: `pkg/reconcilers/networkparams/reconciler.go`] and a `NetworkParamReady` condition on `Network`
[VERIFIED: `network_types.go` printcolumn `PARAM-READY`], but no `NetworkParam` CRD).

There is a **second, incompatible** Kubenet API line in `kubenet-dev/apis` (2024-12-26): groups
`topo.kubenet.dev`, `core.network.kubenet.dev` (`NetworkDesign`) and `device.network.kubenet.dev`
(`Interface`, `SubInterface`, `NetworkInstance`, `BGP`, `BGPNeighbor`, `BGPDynamicNeighbor`, `BFD`,
`RoutingPolicy`, `PrefixSet`, `TunnelInterface`, `TunnelSubInterface`, `NodeTemplate`)
[VERIFIED: kubenet-dev/apis `crds/` listing]. It has **no `Network` CRD at all** — it is the
starlark/choreo direction that was abandoned in December 2024. **Do not pin this line.**

### 1.3 `Network` spec — what it can and cannot express

| 004 field (`contracts/network-spec.md`) | Upstream equivalent | Verdict |
|---|---|---|
| `spec.bridgeDomains[].name` | `spec.bridges[].name` | present (renamed) |
| `spec.bridgeDomains[].l2vni` | `spec.bridges[].networkID` | **conflated**: `networkID` *is* the VNI *and* the EVI *and* the sub-interface index *and* the default VLAN *and* the RT value |
| `spec.bridgeDomains[].vlan` | `spec.bridges[].interfaces[].vlanID` (per attachment) | present, per-interface not per-domain |
| `spec.bridgeDomains[].evpn.routeTargets` | — | **absent**; RT is derived: `target:<iBGP-AS>:<networkID>` [VERIFIED: kuidapps `pkg/devbuilder/builder.go:675`] |
| `spec.bridgeDomains[].irb{vrf,gatewayIPv4,gatewayIPv6}` | `spec.routers[].interfaces[].bridge` + `.addresses[]` | present in *shape* (an IRB is a router interface whose `bridge` names a bridge) — **but no anycast gateway** |
| `spec.routers[].name` | `spec.routers[].name` | present |
| `spec.routers[].l3vni` | `spec.routers[].networkID` | conflated as above |
| `spec.routers[].rd` | — | **absent**; never rendered, SR Linux auto-derives |
| `spec.routers[].routeTargets` | — | **absent**; derived as above |
| `spec.routers[].prefixes` | `spec.routers[].interfaces[].addresses[].address` | different shape (per-interface addresses, not a prefix list) |
| `spec.attachments[]` | `spec.{bridges,routers}[].interfaces[]` | present, nested rather than a flat list |
| `spec.vlans[]` (local-only VLAN, FR-029) | — | **absent, and not expressible**: `BuildOverlay` unconditionally adds `bgp-evpn` + `bgp-vpn` to every bridge [VERIFIED: kuidapps `builder.go:669–678`] |
| **`spec.accessLists[]`** | — | **ABSENT. First-party invention.** |

So, to answer the task's explicit question: **`accessLists` is not an upstream `Network` field.** It exists
only in `/root/agentic-netops/pkg/kubenet/network.go` and in the 004 `contracts/network-spec.md` shape.

### 1.4 What upstream KUID is actually asked for

Only **two** backends are consumed by kuidapps: `ipam.be.kuid.dev/IPClaim` and `as.be.kuid.dev/ASClaim`
[VERIFIED: kuidapps `pkg/devbuilder/api.go:80,94` — `getIPClaim`, `getASClaim`; grep for
`vxlanbev1alpha1|genidbev1alpha1|extcommbev1alpha1|vlanbev1alpha1` across `pkg/` returns nothing].
The VNI (`networkID`) is **supplied by the operator in the `Network` CR**, the VLAN defaults to it, and the
RT is a format string. **Upstream Kubenet does not allocate VNIs, VLANs or route targets.** That is a
first-party responsibility in 004 (FR-062) and stays one.

---

## 2. How upstream Kubenet renders SR Linux

### 2.1 Where the provider lives

`kuidio/nokia-srl` — provider identity string `srlinux.nokia.com`
[VERIFIED: `apis/inv/v1alpha1/node_model_interfaces.go:11` → `NokiaSRLProvider = "srlinux.nokia.com"`],
matching the published docs output `PROVIDER: srlinux.nokia.com`
[VERIFIED: kubenet-dev/docs `docs/02-examples/06_bridgednetwork.md`].

Two controllers [VERIFIED: `pkg/reconcilers/{nodeconfig,deviceconfig}/reconciler.go`]:

- **`SRLNodeConfigController`** — watches `infra.kuid.dev/Node` with `spec.provider == srlinux.nokia.com`,
  expands a `NodeModel` into `Endpoint`/`Module`/`ModuleBay`/`NodeItem` objects, and synthesises a
  system-ID MAC `1A:xx:xx:00:00:00` **from `math/rand` seeded by wall clock**
  [VERIFIED: `nodeconfig/reconciler.go:150–165`]. That is non-deterministic and violates FR-016/Rule 2.
- **`SRLDeviceConfigController`** — watches `network.app.kuid.dev/NetworkDevice`, runs the go-template set,
  and writes the rendered `Config` into `NetworkDevice.status.providerConfig` as a `RawExtension`
  [VERIFIED: `deviceconfig/reconciler.go:141–177`].

### 2.2 `NetworkDevice` → SDC `Config`, verbatim

```go
cfg := configv1alpha1.BuildConfig(
  metav1.ObjectMeta{
    Namespace: cr.GetNamespace(), Name: cr.GetName(),
    Labels: map[string]string{
      "config.sdcio.dev/targetName":      getNodeName(cr.GetName()),   // text after the last '.'
      "config.sdcio.dev/targetNamespace": cr.GetNamespace(),
    }},
  configv1alpha1.ConfigSpec{
    Priority: 10,
    Config: []configv1alpha1.ConfigBlob{{
      Path: "/", Value: runtime.RawExtension{Raw: buf.Bytes()},
    }}}, configv1alpha1.ConfigStatus{})
```
[VERIFIED: kuidio/nokia-srl `pkg/reconcilers/deviceconfig/reconciler.go:146–167`]

The `Config` is then applied by **kuidapps' `Network` reconciler**, not by the provider
[VERIFIED: kuidapps `pkg/reconcilers/network/reconciler.go:229–257` — it unmarshals each
`NetworkDevice.status.providerConfig` and owns `configv1alpha1.ConfigKind`].

Key properties to carry into the spec:
- **One `Config` per (`Network`, node)**, all at `path: "/"`, all at `priority: 10`. The published docs show
  `topo3nodesrl.default.edge01`, `topo3nodesrl.vpc1.edge01`, `topo3nodesrl.vpc2.edge01`,
  `topo3nodesrl.vpc3.edge01` all bound to `Target default/edge01`
  [VERIFIED: kubenet-dev/docs `08_irbnetwork.md`]. **Multiple `Config` objects per `Target` is the normal
  upstream pattern**, not an exception.
- The target binding is **labels**, not an object reference. Those label keys are unchanged in
  config-server v0.0.58 [VERIFIED: `apis/config/label_keys.go:20-21` →
  `TargetNameKey = "config.sdcio.dev/targetName"`, `TargetNamespaceKey = ".../targetNamespace"`].
- `BuildConfig` now takes **two** arguments in v0.0.58 [VERIFIED: `apis/config/config_helpers.go:139`],
  so nokia-srl's three-argument call no longer compiles against current SDC. Trivial, but it is a fact
  about "as-is".

### 2.3 What the templates cover — native SR Linux JSON, nothing else

`templates/main.tmpl` emits exactly six top-level keys [VERIFIED, read in full]:
`system`, `interface[]`, `network-instance[]`, `routing-policy`, `tunnel-interface[]`, `bfd`.

| Construct | Rendered path (native `srl_nokia`) | Template |
|---|---|---|
| Interfaces, breakout, LAG member, `vlan-tagging`, port-speed | `/interface[name]/…` | `srl_interface.tmpl` |
| Sub-interfaces: `type` routed/bridged, `vlan/encap/single-tagged/vlan-id`, IPv4/IPv6 addresses, RA router-role | `/interface[name]/subinterface[index]/…` | `srl_interface_subinterface{,_vlan}.tmpl` |
| Network instances `default`/`mac-vrf`/`ip-vrf` + member interfaces | `/network-instance[name]/{type,interface[],vxlan-interface[]}` | `srl_networkinstance.tmpl` |
| Underlay eBGP/iBGP, peer-groups, RR, dynamic neighbours | `/network-instance[…]/protocols/bgp/…` | `srl_networkinstance_bgp*.tmpl` |
| EVPN | `/network-instance[…]/protocols/bgp-evpn/bgp-instance[1]/{id,admin-state,vxlan-interface,evi,encapsulation-type:"vxlan"}` | `srl_networkinstance_bgpevpn.tmpl` |
| RT | `/network-instance[…]/protocols/bgp-vpn/bgp-instance[1]/route-target/{export-rt,import-rt}` | `srl_networkinstance_bgpvpn.tmpl` |
| VXLAN tunnel | `/tunnel-interface[vxlan0]/vxlan-interface[index]/{type,ingress/vni}` | `srl_tunnel_{interface,subinterfaces}.tmpl` |
| IGP (alt to eBGP) | `/network-instance[…]/protocols/{isis,ospf}/…` | `srl_networkinstance_{isis,ospf}*.tmpl` |
| Routing policy | `/routing-policy/{prefix-set[],policy[]}` | `srl_routingpolicy.tmpl` |
| System EVPN/BGP-VPN containers | `/system/network-instance/protocols/{bgp-vpn,evpn}` | `srl_system.tmpl` |
| BFD | `/bfd/…` | `srl_bfd.tmpl` |

Fixed names: `vxlan0`, `irb0`, `system0`
[VERIFIED: kuidapps `apis/network/v1alpha1/networkdesign_interfaces.go:37-39`].
Instance types: `mac-vrf`, `ip-vrf`, `default`; sub-interface types `routed`, `bridged`
[VERIFIED: `apis/network/v1alpha1/net_types.go:21-33`] — i.e. **the 004 construct vocabulary is SR Linux's
own literal terminology**, which is Open decision 5's premise, and it is upstream's too.

**NOT covered by upstream rendering** — the definitive gap list:

1. **Access lists.** No `acl` key exists in `main.tmpl` at any level. Nothing in `NetworkDevice.spec`
   carries a filter [VERIFIED: kuidapps `apis/network/v1alpha1/networkdevice_type.go` full read].
2. **Anycast gateway.** `srl_interface_subinterface.tmpl` emits plain `ipv4/address[]` on `irb0` with no
   `anycast-gw` [VERIFIED]. SR Linux models it at
   `/interface[name]/subinterface[index]/ipv4/address[ip-prefix]/anycast-gw` (if-feature `anycast-gw`)
   and `…/subinterface[index]/anycast-gw/virtual-router-id`
   [VERIFIED: srlinux-yang-models v25.7.1 `srl_nokia/models/interfaces/srl_nokia-if-ip.yang:171-179`].
   FR-030's symmetric-IRB anycast gateway is therefore **a gap, not a configuration**.
3. **Local-only VLAN (FR-029).** Every bridge unconditionally receives `bgp-evpn` and `bgp-vpn`
   [VERIFIED: kuidapps `builder.go:669–678`]. A bridge domain with no VNI and no EVPN cannot be expressed.
4. **SRv6.** Absent entirely. (SR Linux 25.7.1 *does* model it natively —
   `srl_nokia-srv6-instance.yang`, `srl_nokia-srv6-isis.yang`, `srl_nokia-segment-routing.yang`,
   `srl_nokia-te-policies.yang` [VERIFIED: v25.7.1 `srl_nokia/models/network-instance/` listing] — so this
   is an upstream-provider gap, not a platform gap. That belongs to Open decision 3.)
5. **Explicit RD / RT override.** RT is `fmt.Sprintf("target:%d:%d", iBGP-AS, networkID)`; RD is never set.
6. **Route-distinguisher per-service control, VLAN decoupled from VNI, EVI decoupled from VNI.** All three
   are the same `networkID` integer.
7. **A real defect to know about**: `srl_interface_subinterface_vlan.tmpl` closes the `encap` object only in
   the `single-tagged` branch, so an **untagged** sub-interface emits unbalanced JSON
   [VERIFIED, template read in full]. And `srl_routingpolicy.tmpl` hard-codes
   `"prefix-set": "underlay-ipv4"` / `"underlay-ipv6"` in the policy statements instead of referencing
   `{{$rp.Name}}-ipv4` [VERIFIED]. Upstream-as-is has bugs.

### 2.4 Which SR Linux versions the rendering targets

The published Kubenet walkthrough shows `SCHEMA: srl.nokia.sdcio.dev/24.3.2`
[VERIFIED: kubenet-dev/docs `06_bridgednetwork.md`, `08_irbnetwork.md`] and the repo carries
`sdc/schemas/srl24-3-2.yaml` [VERIFIED: kubenet file listing]. The images in the doc are the **untagged**
`ghcr.io/nokia/srlinux` [VERIFIED: same doc's `docker ps` output]. So the provider's *demonstrated* target is
SR Linux **24.3.2**, ~2.5 years behind the current release train.

---

## 3. SDC (sdcio) — the one part that is current

### 3.1 Release and deployment

Latest **`config-server v0.0.58`**, published 2026-08-19 [VERIFIED: GitHub releases API]. That is exactly
what `/root/agentic-netops/versions.lock.yaml` pins [VERIFIED] — the SONiC build's SDC *version* pin was
right even though nothing it deployed was real.

Three workloads [VERIFIED: sdcio/docs `docs/install/3_k8s_installation.md`, and
config-server `artifacts/{deployment-apiserver,deployment-controller,statefulset-data-server}.yaml`]:

| Workload | Image (as published) | Role |
|---|---|---|
| `api-server` Deployment | `ghcr.io/sdcio/sdc-apiserver:latest` | aggregated APIServer for `config.sdcio.dev` |
| `controller` Deployment | `ghcr.io/sdcio/sdc-controller:latest` | `ENABLE_DISCOVERYRULE`, `ENABLE_CONFIGSET`, `ENABLE_WORKSPACE`, `ENABLE_ROLLOUT` |
| `data-server-controller` StatefulSet | controller + `ghcr.io/sdcio/data-server:v0.0.66` | `LOCAL_DATASERVER=true`, `REVERTIVE=true`, `ENABLE_{SUBSCRIPTION,TARGET,TARGETDATASTORE,TARGETCONFIG,TARGETRECOVERYCONFIG,SCHEMA}` |

[VERIFIED: `artifacts/configmap-input-vars.yaml`, `artifacts/statefulset-data-server.yaml:51-82`,
`artifacts/deployment-controller.yaml:53-82`]

The actual pushed image names are `ghcr.io/sdcio/config-server-api-server` and
`ghcr.io/sdcio/config-server-controller` [VERIFIED: config-server `.goreleaser.yml:34,56`]; the
`sdc-apiserver`/`sdc-controller` names in the ConfigMap are aliases that are **not anonymously pullable**
[VERIFIED: ghcr token + manifest HEAD → 403/000, while `config-server-api-server:v0.0.58` → 200].
**Pin the goreleaser names.** Note also that the published install ships two of three images as `:latest`,
so consuming it verbatim is an NFR-003 violation — the same class of defect the 004 plan already records.

`cert-manager` is a hard prerequisite (the aggregated APIServer's CA bundle)
[VERIFIED: sdcio/docs `docs/getting-started/basic-usage.md` — `cert-manager v1.20.2`].

### 3.2 CRDs, with exact group/version

**`inv.sdcio.dev/v1alpha1`** (storage = served = `v1alpha1` for all of these)
[VERIFIED: config-server `crds/inv.sdcio.dev_*.yaml`, parsed]:
`Schema`, `TargetConnectionProfile`, `TargetSyncProfile`, `DiscoveryRule`, `DiscoveryVendorProfile`,
`Target`, `Subscription`, `Workspace`, `Rollout`.

**`config.sdcio.dev`** — served versions `config` (**storage**) and `v1alpha1` (served, not storage)
[VERIFIED: parsed `crds/config.sdcio.dev_configs.yaml` →
`[('config', storage=True, served=True), ('v1alpha1', storage=False, served=True)]`]:
`Config`, `ConfigSet`, `ConfigBlame`, `Deviation`, `DeviationClear`, `RunningConfig`, `SensitiveConfig`,
`Target`, `TargetBlame`, `TargetClearDeviation`, `TargetRunning`.

Corrections to the task's guesses: there is **no `UnManagedConfig`** kind; brownfield configuration is
surfaced as a **target-scoped `Deviation` of reason `UNHANDLED`** instead. `Target` exists in **both**
groups (`inv.sdcio.dev/Target` is the inventory object, `config.sdcio.dev/Target` the config-side one).

### 3.3 A complete, working SR Linux example (all verbatim from upstream)

**Schema** — [VERIFIED: sdcio/integration-tests `tests/01-crs/schema/schema-nokia-srl-25.7.1.yaml`, the file
SDC's own CI applies]:

```yaml
apiVersion: inv.sdcio.dev/v1alpha1
kind: Schema
metadata: {name: srl.nokia.sdcio.dev-25.7.1, namespace: default}
spec:
  provider: srl.nokia.sdcio.dev
  version: 25.7.1
  repositories:
  - repoURL: https://github.com/nokia/srlinux-yang-models
    kind: tag           # enum: branch | tag | hash   (default tag)
    ref: v25.7.1
    dirs: [{src: srlinux-yang-models, dst: .}]
    schema:
      models:   [srl_nokia/models]     # ← the schema itself: NATIVE ONLY
      includes: [ietf, openconfig]     # ← import resolution only, never models
      excludes: [".*tools.*"]
  - repoURL: https://github.com/sdcio/srlinux-yang-patch
    kind: branch
    ref: v25.7
    dirs: [{src: srl_nokia, dst: deviations}]
    schema: {models: [deviations]}
```

**Secret** — [VERIFIED: sdcio/docs `docs/getting-started/artifacts/secret-srl.yaml`]:

```yaml
apiVersion: v1
kind: Secret
metadata: {name: srl.nokia.sdcio.dev, namespace: default}
type: kubernetes.io/basic-auth
stringData: {username: admin, password: "NokiaSrl1!"}
```

**TargetConnectionProfile** — [VERIFIED: config-server `example/connection-profiles/target-conn-profile-gnmi.yaml`]:

```yaml
apiVersion: inv.sdcio.dev/v1alpha1
kind: TargetConnectionProfile
metadata: {name: gnmi-skipverify, namespace: default}
spec: {port: 57400, protocol: gnmi, encoding: JSON_IETF, skipVerify: true, insecure: false}
```

Full field set and defaults [VERIFIED: parsed `crds/inv.sdcio.dev_targetconnectionprofiles.yaml`]:
`protocol` ∈ `{unknown,gnmi,netconf,noop}` (default `gnmi`); `port` default `57400`;
`encoding` ∈ `{UNKNOWN,JSON,JSON_IETF,PROTO}`; `skipVerify` default **true**; `insecure` default false;
`commitCandidate` ∈ `{candidate,running}` default `candidate`; `connectRetry` `10s`; `timeout` `10s`;
`includeNS`, `operationWithNS`, `useOperationRemove` default false; `preferredNetconfVersion` `1.0`;
`targetName` (gNMI prefix target).

**TargetSyncProfile** — [VERIFIED: `example/sync-profiles/target-sync-profile-gnmi.yaml`]:

```yaml
apiVersion: inv.sdcio.dev/v1alpha1
kind: TargetSyncProfile
metadata: {name: gnmi-get, namespace: default}
spec:
  buffer: 0
  workers: 10
  validate: true
  sync:
  - {name: config, protocol: gnmi, paths: ["/"], mode: get, encoding: JSON_IETF, interval: 30s}
```

`mode` ∈ `{unknown,onChange,sample,once,get}` (default `get`); `encoding` adds `CONFIG`
[VERIFIED: parsed CRD]. An on-change variant also ships
[VERIFIED: `target-sync-profile-gnmi-once-and-onchange.yaml` — `mode: onChange, encoding: PROTO` plus a
`mode: once, encoding: JSON_IETF, interval: 30s`], and SDC CI exercises SRL on-change encodings
[VERIFIED: `tests/03-deviations/13-srl-onchange-encodings.robot`].

**DiscoveryVendorProfile** (required from v0.0.5x; the discovery controller learns version/platform/hostname
from it) — [VERIFIED: `example/discoveryvendor-profile/discoveryvendor-profile-nokia-srlinux.yaml`]:

```yaml
apiVersion: inv.sdcio.dev/v1alpha1
kind: DiscoveryVendorProfile
metadata: {name: srl.nokia.sdcio.dev, namespace: default}
spec:
  gnmi:
    organization: Nokia
    modelMatch: nokia.com:srlinux
    paths:
    - {key: version,      path: platform/control[slot=A]/software-version, regex: '^v?(\d+\.\d+\.\d+)'}
    - {key: platform,     path: platform/chassis/type}
    - {key: hostname,     path: system/name/host-name}
    - {key: serialNumber, path: platform/chassis/serial-number}
    - {key: macAddress,   path: platform/chassis/hw-mac-address}
```

**Static targets** (recommended for a clab lab — "no discovery": fixed mgmt IPs, fixed schema) —
[VERIFIED: `example/discovery-rule/nodiscovery.yaml`]:

```yaml
apiVersion: inv.sdcio.dev/v1alpha1
kind: DiscoveryRule
metadata: {name: dr-static, namespace: default}
spec:
  period: 1m
  concurrentScans: 2
  defaultSchema: {provider: srl.nokia.sdcio.dev, version: 25.7.1}   # ← no discoveryProfile ⇒ no probing
  addresses:
  - {address: 172.31.0.11, hostName: leaf01}
  - {address: 172.31.0.12, hostName: leaf02}
  - {address: 172.31.0.21, hostName: spine01}
  - {address: 172.31.0.22, hostName: spine02}
  targetConnectionProfiles:
  - {credentials: srl.nokia.sdcio.dev, connectionProfile: gnmi-skipverify, syncProfile: gnmi-get}
  targetTemplate:
    labels: {sdcio.dev/region: dc1}
```

Adding `spec.discoveryProfile.{credentials,connectionProfiles[]}` turns on real discovery
[VERIFIED: `example/discovery-rule/discovery_address.yaml`]. `DiscoveryRule` also supports `prefixes[]`
(with `excludes`), `podSelector`, `serviceSelector`+`serviceDomain`, `tlsSecret` for mTLS, and a
`targetTemplate.nameTemplate` [VERIFIED: parsed CRD].

**Config** — [VERIFIED: `example/config/config.yaml`, `config-orphan.yaml`]:

```yaml
apiVersion: config.sdcio.dev/v1alpha1     # storage version is `config`; v1alpha1 still served
kind: Config
metadata:
  name: vpc1-leaf01
  namespace: default
  labels:
    config.sdcio.dev/targetName: leaf01
    config.sdcio.dev/targetNamespace: default
spec:
  priority: 10
  revertive: true                       # omit ⇒ inherit the REVERTIVE env var (deployed default "true")
  lifecycle: {deletionPolicy: delete}   # enum: delete (default) | orphan
  config:
  - path: /
    value: { interface: [ {name: system0, admin-state: enable} ] }
```

`ConfigSet` is the same spec plus `spec.target.targetSelector` (label selector) and a per-target status list
[VERIFIED: parsed `crds/config.sdcio.dev_configsets.yaml`; `example/config/configset.yaml`].

### 3.4 Priority, ownership, deviation and revertive behaviour — the rules that decide §6

**Priority (authoritative wording)**: *"Resolves conflicts between Config intents that set overlapping
configuration. Where they overlap, the value from the intent with the **lowest priority number** is
applied."* [VERIFIED: sdcio/docs `docs/user-guide/configuration/config/config.md`]. Confirmed in the
implementation: `GetHighestPrecedenceValueOfBranch` documents *"the highest precedence value (lowest
priority value)"* [VERIFIED: data-server@efcdd7bd `pkg/tree/ops/gethighestprecedencevalueofbranch.go:9-11`].

**Equal priorities are NOT resolved.** The selection loop compares with a strict `>`:
```go
if highest.Priority() > e.Priority() { secondHighest = highest; highest = e } else { … }
```
[VERIFIED: data-server `pkg/tree/api/leaf_variants.go:325-345`]. Two intents at the *same* priority writing
the *same* leaf produce a winner determined by iteration order over `lv.les` — i.e. **undefined**. Any
design that puts two `Config` objects on one leaf **must give them distinct priorities.**

**Deviation types** [VERIFIED: sdcio/docs `docs/user-guide/deviation.md`]:

| Type | Meaning | SDC action |
|---|---|---|
| `UNHANDLED` | no matching Config CR (brownfield) — reported as a **target**-scoped `Deviation` | report only |
| `NOT_APPLIED` | matching Config exists, device differs | **revertive: reapply; non-revertive: accept as active** |
| `OVERRULED` | matching Config exists but a **higher-priority (lower number)** intent overrode it | report only, never fight |

`Deviation.spec` = `{deviationType: target|config, deviations[]: {path, desiredValue, actualValue, reason}}`
[VERIFIED: parsed `crds/config.sdcio.dev_deviations.yaml`; `apis/config/deviation_types.go:36-37`;
`apis/config/v1alpha1/deviation_helpers.go:38` tests `dev.Reason == "NOT_APPLIED"`]. Names are prefixed
`config-<name>` / `target-<name>` [VERIFIED: `apis/config/deviation_helper_test.go:27-28`]. One `Deviation`
is created per target **and** one per Config [VERIFIED: deviation.md's worked `kubectl get deviations` output].

**Revertive** is global via the `REVERTIVE` env var on the data-server-controller (deployed as `"true"`
[VERIFIED: `artifacts/statefulset-data-server.yaml:59-60`]) and overridable per Config via `spec.revertive`
[VERIFIED: config.md]. Clearing a deviation is an explicit operator action via `kubectl-sdc` /
`DeviationClear` / `TargetClearDeviation` [VERIFIED: deviation.md + CRD listing]. **FR-015's "lab revertive
mode" is therefore a two-line configuration on SR Linux, and it is covered by SDC's own CI**
[VERIFIED: `tests/03-deviations/{12-srl-revertive,22-srl-nonrevertive}.robot` against `ghcr.io/nokia/srlinux:25.7.1`].

**Intended / running / applied**: `Config.status.appliedConfig` mirrors the last successfully applied spec;
`Config.status.lastKnownGoodSchema{vendor,type,version}` records the schema it was applied under;
`Config.status.deviationGeneration` ties the deviation set to a generation
[VERIFIED: parsed `crds/config.sdcio.dev_configs.yaml` status]. `RunningConfig` /`TargetRunning` expose the
device's running config as `status.value`; `ConfigBlame`/`TargetBlame` expose per-leaf intent ownership
[VERIFIED: parsed CRDs]. **`ConfigBlame` is the mechanism that makes Rule 4 ("one owner per managed path")
machine-checkable** rather than aspirational.

**Transactions and rollback**: `TransactionSet(… DryRun bool) → TransactionConfirm | TransactionCancel`
[VERIFIED: config-server `pkg/sdc/dataserver/client/client.go:359-368`;
`pkg/sdc/target/manager/transactor.go:139-166, 328-331`]. A dry-run returns without confirming
(`if req.DryRun { return … }` at `transactor.go:162`). Failures are classified into
`TransactionResult{GlobalError, IntentErrors, GlobalWarnings, Recoverable}`, and **any intent error is
non-recoverable** [VERIFIED: `transactor.go:763-785`]. On target reconnect, `RecoverConfigs` replays every
Config that has a `status.appliedConfig` [VERIFIED: `transactor.go:60-105`]; failure to recover sets
`ConfigFailed` on **every** Config of that target [VERIFIED: `SetConfigsTargetConditionForTarget`].

**Validation** happens in the data-server *before* anything is sent to the device: mandatory statements,
leafrefs (incl. min/max), patterns, must-statements, length, range, max-elements — all on by default,
individually disableable via the data-server ConfigMap `validation-defaults.disabled-validators`
[VERIFIED: sdcio/docs `docs/user-guide/disablevalidation.md`]. Errors surface as condition
`ConfigReady=False, reason=failed, message=<joined intent errors>`
[VERIFIED: `apis/config/v1alpha1/condition.go:82-92`]. In-flight states are
`ConfigReady=False reason=creating|updating` [VERIFIED: same file:47-68]; the dependency condition is
`TargetForConfigReady` [VERIFIED: same file:27-28,95+]; `Ready` is the computed overall
(`SetOverallStatus()`).

**Offline validation for CI** — `sdc-lite` loads a Schema CR and one or more intents at chosen priorities
and offers `config validate`, `config diff`, `config show`, and **`config blame`** entirely offline, no
cluster and no device [VERIFIED: sdcio/docs `docs/cli-tools/sdc-lite.md`; repo `sdcio/sdc-lite`, last push
2026-08-24]. This is the tool that makes FR-014/FR-045 golden-file determinism and the §6 ownership rule
testable in CI.

### 3.5 Known limitations

- Published install manifests use `:latest` for two of three images (§3.1).
- `Config.spec.config[].value` is `x-kubernetes-preserve-unknown-fields` — **the Kubernetes API server
  performs no validation of it at all**; all validation is data-server-side and therefore asynchronous
  unless you dry-run through `sdc-lite` first. A server-side `kubectl apply --dry-run=server` proves
  nothing about the device payload. This matters for CR-004 / FR-065 ("server-side dry-run") — on SDC the
  meaningful dry-run is `TransactionSet{DryRun:true}` or `sdc-lite`, **not** the API server's.
- The YANG deviation patch repo `sdcio/srlinux-yang-patch` has branches only through `v25.7`
  [VERIFIED: `git ls-remote --heads`: `main, v24.7, v24.10, v25.3, v25.7`; `v24.10`, `v25.3` and `v25.7` all
  point at the **same** commit `7410316d34f1d393b82889c0caa1b5acef80fb60`]. Nothing exists for 25.10, 26.3
  or 26.7. **This is the hard ceiling on how new an SR Linux you can pin.**
- Equal-priority overlap is undefined (§3.4).
- Discovery-driven `Target` naming is template-driven; a clab redeploy that changes mgmt IPs changes nothing
  if you use `nodiscovery` + `hostName`, but does churn Targets if you use prefix scanning.

---

## 4. KUID — exact groups and kinds

Aggregated APIServer (`kuid-server`), not CRDs [VERIFIED: kuid `artifacts/apiservice-*.yaml`,
`artifacts/deployment.yaml`]. Groups registered by the published artifacts
[VERIFIED: each `apiservice-*.yaml` read]:

| Group | Kinds (Index / Claim / Entry triple) | Backend present at HEAD? |
|---|---|---|
| `ipam.be.kuid.dev/v1alpha1` | `IPIndex`, `IPClaim`, `IPEntry` | yes [VERIFIED: `apis/backend/ipam/v1alpha1/`] |
| `as.be.kuid.dev/v1alpha1` | `ASIndex`, `ASClaim`, `ASEntry` | yes |
| `vlan.be.kuid.dev/v1alpha1` | `VLANIndex` (`minID`/`maxID`), `VLANClaim`, `VLANEntry` | yes |
| `genid.be.kuid.dev/v1alpha1` | `GENIDIndex` (`type`: 16/32/48/64-bit), `GENIDClaim`, `GENIDEntry` | yes |
| `extcomm.be.kuid.dev/v1alpha1` | `EXTCOMMIndex` (`type: ipv4Address`, `subType: target`, `globalID`), `EXTCOMMClaim`, `EXTCOMMEntry` | yes |
| `vxlan.be.kuid.dev/v1alpha1` | `VXLANIndex`, `VXLANClaim`, `VXLANEntry` | **APIService registered but `apis/backend/vxlan` is GONE at HEAD** |
| `infra.kuid.dev/v1alpha1` (note: **not** `infra.be.kuid.dev`) | `Node`, `Link`, `Endpoint`, `Module`, `ModuleBay`, `NodeItem`, `Adaptor`, `Port`, `NodeSet`, `LinkSet`, `EndpointSet`, `Cluster`, `Partition` | yes [VERIFIED: `apis/infra/v1alpha1/*_types.go`] |

[VERIFIED: `apis/backend/` at `be8e5686` contains only `as extcomm genid ipam vlan`; `examples/vxlan/*.yaml`
still use `apiVersion: vxlan.be.kuid.dev/v1alpha1 kind: VXLANIndex|VXLANClaim`; `examples/genid/index.yaml`
is itself stale, using `apiVersion: id.be.kuid.dev/v1alpha1 kind: IDIndex`.]

**Corrections to `contracts/kuid-claim-profiles.md` §1:**
- The group names it lists are right (`*.be.kuid.dev`) — D-22's supersession holds.
- `genid.be.kuid.dev/GENIDIndex` **32-bit** works for VNIs, but `vxlan.be.kuid.dev/VXLANIndex` is the
  purpose-built one; on SR Linux the VNI range is 1–16777215. Recommend **VXLAN** for VNIs, and drop GENID
  unless the vxlan backend's absence at HEAD proves fatal at runtime, in which case GENID/32-bit is the
  fallback. Record which you used — this is a real, evidence-backed fork in the road.
- `extcomm.be.kuid.dev/EXTCOMMIndex` requires `type` + `subType` + `globalID`, e.g.
  `{type: ipv4Address, subType: target, globalID: <AS or router-id>}` — the contract's "2-byte AS target,
  1–65535, global AS" is expressible but the field names are `type`/`subType`/`globalID`, not a range.
- `vlan.be.kuid.dev/VLANIndex` takes `minID`/`maxID` [VERIFIED: `examples/vlan/index.yaml`], so the
  100–4000 band is a per-index setting, as the contract assumes.
- ASN: `ASIndex.spec.claims[]` supports named sub-claims, e.g.
  `{name: aspool, range: 65000-65100}` and `{name: ibgp, id: 65535}` [VERIFIED: `examples/asn/index.yaml`] —
  exactly the shape `NetworkDesign.spec.protocols.{ebgp.asPool, ibgp.as}` consumes.

**What SR Linux EVPN actually needs allocated**: VNI (L2 + L3), EVI, RD, RT, VLAN, ASN, IPs. Upstream
conflates VNI = EVI = VLAN = RT-local-part and derives RD implicitly. If 004 keeps FR-062 ("every identifier
from the allocation authority") it must claim **VNI** (vxlan or genid), **VLAN** (vlan), **RT** (extcomm),
**ASN** (as), **IPs** (ipam) itself — upstream will claim only IP and AS.

---

## 5. RECOMMENDATION — Open decision 1 (southbound)

> **Adopt `provider → SDC `Config` → gNMI(JSON_IETF, TLS) → SR Linux` as the only southbound, and delete
> the executor, the `docker exec` path, the raw-store client and the whole-config-versus-raw-store split
> entirely. No escape hatch.**

### Justification

1. **The escape hatch's only justification was SONiC-specific and is gone.** D-12/PC-12's rationale is
   verbatim: a YANG-invalid whole-config write *"poisons every subsequent whole-config write image-wide"*,
   and the ACL table's port list is a leafref into a port table whose rows the fabric's kernel devices are
   not [VERIFIED: research.md D-12]. On SR Linux there is no GCU, no CONFIG_DB, and no such poisoning
   failure mode. Sub-interfaces are first-class YANG list entries, and the ACL binding leafref
   (`/acl/interface[interface-id]/interface-ref/{interface,subinterface}`) resolves against
   `/interface[name]/subinterface[index]` — objects the platform itself creates
   [VERIFIED: srlinux-yang-models v25.7.1 `srl_nokia-acl.yang:1788-1817`]. The leafref that could not
   resolve on SONiC **does** resolve on SR Linux.
2. **Validation moves left.** SDC validates mandatory/leafref/pattern/must/length/range/max-elements before
   a single byte reaches the device [VERIFIED: disablevalidation.md], and `sdc-lite` does the same offline
   in CI. The class of failure that motivated the escape hatch is now caught before apply.
3. **Transaction, rollback, recovery, drift and blame are upstream features, already CI-tested against
   SR Linux 25.7.1** (§3.4). Reimplementing them host-side would be strictly worse.
4. **FR-007 and D-02 stop having a silent exception.** The executor was the only host-side component; it is
   the only reason FR-007 is violated [VERIFIED: platform-coupling.md §Recorded divergence].
5. **Keeping an escape hatch has a cost with no benefit.** It would require re-deriving PC-11–PC-13 against
   SR Linux's configuration store (there isn't one — SR Linux's store *is* its YANG datastore over gNMI),
   and it would reintroduce a second translation implementation, which FR-060/PC-N-07 forbids.

### Spec artefacts deleted as a consequence

**Delete outright:**
- `platform-coupling.md` §Recorded divergence (the whole section), and its forward references in
  `contracts/crd-api.md` §API boundary clause 5, `contracts/reconciliation.md` Rule 5, plan.md §Summary and
  §Technical Context §Southbound.
- **PC-11** (CONFIG_DB/ASIC_DB table and db numbers; `redis-hget`, `redis-exists`, `redis-hget-contains`,
  `redis-keys-match` check types; database-selectable read).
- **PC-12** (GCU-vs-raw-redis split and the whole-config poisoning hazard). The concept ceases to exist.
- **PC-13** (`SAI_ACL_BIND_POINT_TYPE_PORT` vs `…_SWITCH`, the stock-leaf baseline).
- **PC-16** second half (the port map from attachment names to kernel devices that are not port-table rows).
- **D-12** in `research.md` (entirely — it is an argument about a store that no longer exists).
- **R-25** (the poisoning risk) and **R-26** (the switch-wide applied-check defect, whose subject is the
  redis read path). R-26's *lesson* — a check that passes on a stock device is not a check — must be
  restated as a test obligation against `ConfigBlame`/`RunningConfig`, not deleted silently.
- `contracts/reconciliation.md` §Contract tests row **"Access-list placement — no access-list operation is
  ever emitted as a whole-config write."** Replace with a `ConfigBlame` ownership assertion (§6).
- **C-08**'s `cmd/fabric-executor` from the plan's component inventory, and `cmd/fabric-executor` from
  plan.md §Technical Context's package list.
- `contracts/acl-render-contract.md` §2 (raw-store row shapes), §4 (ASIC_DB read-back), §4.2 (stock-leaf
  baseline) — the ACL agent owns the replacement, but the *deletion* follows from this decision.

**Rewrite, do not delete:**
- **FR-015** — keep, and make it concrete: intended = `Config.spec`, applied = `Config.status.appliedConfig`,
  running = `RunningConfig`/`TargetRunning`, deviation = `Deviation` with `UNHANDLED|NOT_APPLIED|OVERRULED`;
  lab revertive = `REVERTIVE=true` globally plus `spec.revertive` per Config; production policy explicit.
- **FR-042 / PC-N-13** — two-sided read-back becomes `Config.status.appliedConfig` (config side) **plus**
  `RunningConfig`/`ConfigBlame` (device side), scoped by intent name. This is *stronger* than what SONiC
  could offer and closes R-26's defect class by construction.
- **CR-004 / FR-065** — "server-side dry-run" must be re-worded. The Kubernetes API server cannot validate
  `Config.spec.config[].value` (§3.5). The dry-run that counts is `TransactionSet{DryRun:true}` or
  `sdc-lite config validate`. Leaving the wording as-is would make a meaningless check look like a gate.
- **FR-007 / D-02** — delete the "carried tension" paragraphs; the exception is gone.

**Add:**
- A requirement that **cert-manager** is a pinned prerequisite of the control plane (SDC's aggregated
  APIServer needs it) [VERIFIED: §3.1].

---

## 6. RECOMMENDATION — Open decision 2 (provider ownership)

> **Option (b), with upstream as a read-only reference: build a first-party
> `agentic-netops-srl-provider` that consumes the upstream `network.app.kuid.dev` APIs unchanged and is the
> single renderer of every SR Linux path — underlay, overlay, IRB, anycast gateway and ACL alike.**
>
> **Reject (a)** (upstream as-is) and **reject (c)** (upstream + gap controller).

### Why not (a) — upstream as-is

- It is dormant (§0 Finding B): `kuidio/nokia-srl` has not been touched since **2024-06-11**, `kuidapps`
  since 2024-11-24, `kuid` since 2025-02-17. There have been **eight** SR Linux release trains since
  (24.7, 24.10, 25.3, 25.7, 25.10, 26.3, 26.7 [VERIFIED: `git ls-remote --tags nokia/srlinux-yang-models`]).
- Its demonstrated target is SR Linux **24.3.2** (§2.4).
- It does not compile against current SDC (`BuildConfig` arity, §2.2).
- It renders none of ACL, anycast gateway, local VLAN, explicit RD/RT, SRv6 (§2.3).
- It has real emission bugs (untagged-VLAN JSON, hard-coded prefix-set name) and a non-deterministic
  `math/rand` system-ID (§2.1, §2.3) that violates FR-016 and Rule 2 head-on.
- NFR-003 cannot be met from its published artifacts (all `:latest`).

Adopting (a) would mean pinning a 22-month-dormant, provably buggy, non-deterministic renderer as the
system's only southbound. That is not a smaller risk than writing one; it is a larger one with no owner.

### Why not (c) — upstream + a first-party gap controller

This is the option that looks cheapest and is the one to refuse most firmly, on two independent grounds.

**Ground 1 — it breaks the ONE-TRANSLATOR rule (FR-060 / PC-N-07) in its own terms.**
PC-N-07 is *"intent becomes fabric intent in exactly one place, and the access-list render is a field on the
same fabric intent object rather than a second path."* Under (c), the ACL render **cannot** be a field on
the same fabric intent object, because the upstream `Network` has no `accessLists` field and never will
(§1.3, §0 Finding C). The ACL intent has to arrive by some other route — a second CRD, an annotation, or a
fork — and a second controller has to watch that route and emit a second `Config`. That is, by the
requirement's own definition, **a second path**. D-09 made exactly this argument against a second ACL render
on SONiC and it applies unchanged.

It is also two translators in the strict sense: a `mac-vrf` with a filter would have its bridge-domain half
rendered by the upstream provider and its filter half by the gap controller, from two different input
objects, with two different render-hash lineages, two different `Config` generations, and no single object
whose `Ready` means the operator got what they asked for. FR-018 ("partial success never reported as
ready") would have to be re-specified across two controllers.

**Ground 2 — the SDC ownership semantics make it fragile even where it is legal.**
Two `Config` objects on one `Target` touching the same sub-interface:
- If both sit at **the same priority**, the winner on any shared leaf is **undefined** (strict `>`
  comparison, §3.4). Silent, non-deterministic displacement — the exact hazard D-14/D-15 refuse.
- If they sit at **different** priorities, the loser is permanently reported as an `OVERRULED` deviation and
  SDC will never fight it [VERIFIED: deviation.md]. So the gap controller's ACL `Config` would have to be at
  a *lower number* (higher precedence) than the fabric `Config` for the ACL to stick — which inverts the
  natural reading ("fabric is the base, ACL is the overlay") and means **any** future overlap of the ACL
  `Config` with a fabric leaf silently wins over the fabric intent.
- And they *do* overlap. The ACL binding lives at `/acl/interface[interface-id]/…/interface-ref/subinterface`,
  whose leafref targets `/interface[name]/subinterface[index]` with a `must` requiring the sub-interface
  `type` to be `bridged` or `routed` [VERIFIED: `srl_nokia-acl.yang:1798-1817`]. The two controllers are
  therefore coupled through the sub-interface's existence and type. Ordering, not just priority, becomes a
  correctness property across two independent reconcilers.

(c) is defensible only in the narrow form "upstream renders the fabric, gap controller renders `/acl` at a
**disjoint** subtree with a **documented distinct priority**". Even that disjointness is not guaranteed
(the leafref coupling above), and it does not rescue Ground 1.

**Against NFR-007** ("the intent tier must remain removable with every control-plane gate still passing"):
(c) is neutral on NFR-007 itself — the gap controller is control-plane, not tier. But it damages
**NFR-006's sibling property, dependency direction**, by making the control plane's correctness depend on
the *ordering* of two controllers neither of which owns the other. And it makes the removability test
ambiguous: if the gap controller is removed, half the constructs silently degrade rather than fail.

### Why (b) — and how to keep FR-013 honest

**FR-013 says "reuse the pinned upstream *APIs* … instead of introducing duplicate fabric or
device-configuration CRDs."** It does not say "reuse the upstream *controllers*." Option (b) honours it
exactly:

| Layer | Owner under (b) |
|---|---|
| `topo.app.kuid.dev/Topology`, `infra.kuid.dev/{Node,Link,Endpoint,…}` | **upstream KUID**, unchanged |
| `ipam/as/vlan/vxlan/extcomm.be.kuid.dev` indices and claims | **upstream KUID**, unchanged |
| `network.app.kuid.dev/{Network, NetworkDesign, NetworkDevice}` | **upstream kuidapps CRDs**, unchanged — no new fabric CRD |
| `NetworkDevice` → SR Linux JSON → `config.sdcio.dev/Config` | **first-party `agentic-netops-srl-provider`**, replacing `kuidio/nokia-srl` |
| `inv.sdcio.dev/*`, `config.sdcio.dev/*` | **upstream SDC**, unchanged — no new device-configuration CRD |

No CRD is duplicated. One controller binary is replaced by a first-party one that filters on
`NetworkDevice.spec.provider` — the upstream extension point that already exists
[VERIFIED: `deviceconfig/reconciler.go:109` filters on `cr.Spec.Provider`]. Use a distinct provider string,
e.g. `srlinux.agentic-netops.io`, so the two can coexist during bring-up and a regression test can diff
first-party output against upstream's for the constructs upstream does cover.

Run `kuidapps` itself (it derives `NetworkDevice` from `Network` and applies the `Config` from
`status.providerConfig`), or replace it too if its version skew (§1.2) proves unworkable — but that is a
build decision, not a spec one, and the spec should state the API contract, not the binary.

### How ACL intent is carried — the answer FR-013 needs

Ranked, with the recommendation first.

**R1 (recommended) — extend `NetworkDevice`, not `Network`, and carry operator ACL intent on the
first-party service object that already exists.**
The 004 architecture already has exactly one object between the operator and the fabric: the normalized
service-intent contract the single translator emits (FR-060). Today that contract is *rendered into* a
`Network`. Under (b) it should be rendered into a **first-party `FabricService` (or keep the existing
`Network`-shaped object under `agentic-netops.io/v1alpha1`)** which carries `bridgeDomains`, `routers`,
`vlans`, `attachments` **and** `accessLists` as fields of one object, and whose controller then:
1. projects the fabric half onto an upstream `network.app.kuid.dev/Network`, and
2. renders **everything** — fabric and ACL — into per-device `Config` objects through the one provider.

This keeps FR-060 literally true ("the access-list render is a field on the same fabric intent object"),
introduces **one** first-party CRD rather than two, and introduces **zero** duplicate *device-configuration*
CRDs. FR-013 should be reworded to say what it actually means: *reuse the upstream device-configuration API
(`Schema`, `Target`, `Config`) and the upstream allocation API unchanged; reuse the upstream fabric API
where it is expressive enough; and where it is not, extend in exactly one first-party object rather than in
a second controller.* That is honest, and it is what the system will do either way.

**R2 — annotation on the upstream `Network`.** Carrying `accessLists` as a JSON blob in
`agentic-netops.io/access-lists` keeps the object count at zero-new-CRDs but makes the ACL intent
unvalidatable by the API server, invisible to `kubectl explain`, and impossible to dry-run. It also makes
GAP-3 (three actors stamping metadata with no precedence) materially worse by putting *payload* in
metadata. Do not.

**R3 — fork kuidapps to add `spec.accessLists`.** Technically clean (the field lands where PC-N-07 wants
it), but it forks a dormant upstream and makes every future rebase a merge conflict in the type that the
whole data model rests on. Only choose this if R1's extra object is judged unacceptable.

**R4 — a separate first-party `AccessList` CRD.** This is (c) in CRD clothing: two objects, two renders,
two readiness stories. Reject for the same reasons as (c).

### Config ownership and priority between two Config objects on one Target

Even under (b), the system emits **multiple** `Config` objects per `Target` (one per `Network`/service, as
upstream does). Specify the ownership rule explicitly:

1. **One `Config` per (service, node).** Name it deterministically from the service identifier and the node
   (upstream uses `<network>.<node>`; keep a derivation, since the `targetName` label is parsed as "text
   after the last dot" [VERIFIED: `getNodeName` in `deviceconfig/reconciler.go:180-187`] — a dot in a
   service name silently mis-targets).
2. **A reserved priority band per layer, all distinct**, because equal priority is undefined (§3.4):
   - `priority: 10` — the default/underlay fabric `Config` (matches upstream).
   - `priority: 20` — per-tenant overlay service `Config` objects.
   - **No two `Config` objects may share a priority if they can touch the same leaf.** Where two tenant
     services legitimately touch one sub-interface, that is a *conflict to refuse at validation*, not a
     priority to resolve — same doctrine as D-14.
3. **`lifecycle.deletionPolicy: delete`** on everything the platform owns (the default), so finalization
   removes device state. `orphan` is a documented break-glass only.
4. **`revertive: true`** in lab; production policy explicit (FR-015).
5. **The ownership assertion is machine-checked**: for each managed path, `ConfigBlame`/`TargetBlame` must
   name this service's intent and no other; any `OVERRULED` deviation on a platform-owned path is a
   **terminal error**, not a warning (Rule 4: "conflicting ownership … is a terminal error until explicitly
   resolved"). This replaces the deleted whole-config-write assertion and closes R-26's class of defect
   with a real, device-sourced check.

---

## 7. The compatibility set, restated for SR Linux (replaces PC-01)

The SONiC five-part set was *image + YANG schema commit + mapping version + containerlab + observability*.
On SR Linux the set is **nine parts**, because the schema is assembled from two repositories and the
control plane is three independently-released projects.

| # | Part | Recommended pin | Evidence |
|---|---|---|---|
| 1 | **SR Linux image** | `ghcr.io/nokia/srlinux:25.7.1` @ `sha256:6ab1250cbff4b536e0996e57d2d9c2a7bf3154028c21e4c978e13254add3c402` | [VERIFIED: ghcr manifest HEAD]. Chosen because sdcio's own CI runs this exact tag [VERIFIED: sdcio/integration-tests `containerlab/citest.clab.yml:11`]. |
| 2 | **srlinux-yang-models** | tag `v25.7.1` = commit `badcf9977fe672437907cdae7daebb27a1361c36` | [VERIFIED: `git ls-remote --tags nokia/srlinux-yang-models`] |
| 3 | **sdcio YANG deviation patch** | `sdcio/srlinux-yang-patch` branch `v25.7` — **pin as `kind: hash, ref: 7410316d34f1d393b82889c0caa1b5acef80fb60`**, not as a branch | [VERIFIED: `git ls-remote --heads`]. A branch ref is mutable and violates NFR-003; the `Schema` CRD supports `kind: hash` [VERIFIED: parsed CRD enum `branch\|tag\|hash`]. |
| 4 | **SDC `Schema` CR** | `provider: srl.nokia.sdcio.dev`, `version: 25.7.1`, `models: [srl_nokia/models]`, `includes: [ietf, openconfig]`, `excludes: ['.*tools.*']` | [VERIFIED: sdcio/integration-tests `tests/01-crs/schema/schema-nokia-srl-25.7.1.yaml`] |
| 5 | **SDC release** | `config-server v0.0.58`; images `ghcr.io/sdcio/config-server-api-server:v0.0.58` @ `sha256:bd5d312512ad7484eadb6b8e43ef550f647034abdead80429b8ba17d74041f9e`, `ghcr.io/sdcio/config-server-controller:v0.0.58` @ `sha256:01c69c589137579db784c769019bc92591899666714f153b5b4b97a761ffea13`, `ghcr.io/sdcio/data-server:v0.0.66` @ `sha256:fe138dcfcfeb5bee2a615bd4e9616bafc9d27b57ae55cee9360d4fd0d2cecbf7` | [VERIFIED: releases API; ghcr manifest HEADs; `artifacts/configmap-input-vars.yaml` declares data-server v0.0.66 for this release] |
| 6 | **KUID release** | `kuid-server v0.0.7` @ `sha256:24411cecfb76f89b1740c841c7fc1eede8718e6e823b3736dc9e4f7e19c0b714` — **the version the Kubenet bundle actually pins**, and the version kuidapps/nokia-srl compile against | [VERIFIED: kubenet `artifacts/kubenet-release.yaml`; kuidapps `go.mod:11` `github.com/kuidio/kuid v0.0.7`; nokia-srl `go.mod:7` same; ghcr manifest]. `v0.0.13` @ `sha256:d6fdae78cc5ba4d14655ef2e77bc3c38eb8201679b52aef56bf550e332800608` exists but is **not** what the rest of the set was built against. |
| 7 | **Kubenet release** | there is none. Pin `kubenet-dev/kubenet` commit `9c91bb81566d0da8138c3be39f4fbed40b772ac6` for artifacts, and pin the two controller images it names: `ghcr.io/kuidio/kuidapps:v0.0.33` @ `sha256:3a9c1f1ebee88675af2b7c967c3e2c1fd21961cea2dda4f9c0ff139112bd0e05`; (reference only) `ghcr.io/kuidio/nokia-srl:v0.0.15` @ `sha256:6e54f3580a9b766f3f2ce6a5879eca7472907134f518ce34cab63d1ad20c9606` | [VERIFIED: shallow clone HEAD; releases API; ghcr manifests] |
| 8 | **containerlab** | `0.79.0` (host, commit `5ae50094a`) | [VERIFIED: `containerlab version` on this host] |
| 9 | **gnmic** | `0.47.0` (host) | [VERIFIED: /root/agentic-netops/versions.lock.yaml `host_tools.gnmic`; host tooling stated in PREAMBLE] |
| — | **mapping version** | first-party, e.g. `srl-mapping v0.1.0`, stamped on every `Config` as an annotation and asserted by the provider against parts 1–4 | design decision |

**Why not a newer SR Linux.** Images exist for `25.10.1`
(@`sha256:bc8112667b5a87bee5039ade65b504ac2ef35511210d0675db6c7b0754e8cc4c`), `26.7.1`
(@`sha256:2c9318fa3bcbc7667198e9c4cb268864cb287409e89eef2768f06cfadda6a6a3`) and `26.7.2`
(@`sha256:0096fe3ebcafabb7253492e2060425fe027a168e0e066766d1e85efbb0b48be8`); `26.3.1` is **not** publicly
pullable [VERIFIED: all four checked via ghcr manifest HEAD]. YANG model tags exist through `v26.7.2`
[VERIFIED: `git ls-remote --tags`]. But **`sdcio/srlinux-yang-patch` stops at `v25.7`** (§3.5), and
containerlab changes the SR Linux TLS config path at **26.3** (`system tls profile` replaces
`system tls server-profile` [VERIFIED: containerlab@main `nodes/srl/version.go:236-240`,
`version_configs/tls.cfg` vs `tls_pre26_3.cfg`]). Pinning 25.7.1 gets: SDC's own CI coverage, a matching
deviation patch, containerlab's stable pre-26.3 TLS path, and OpenConfig auto-enablement (≥24.10).

**Mutual-compatibility caveats, stated so a reader does not discover them at compile time:**
- `kuidapps@0c1a0b2e` imports `github.com/kuidio/kuid/apis/backend/infra/v1alpha1`
  [VERIFIED: `pkg/devbuilder/api.go:33`], a path that **no longer exists at kuid HEAD** (it moved to
  `apis/infra/v1alpha1`, group `infra.kuid.dev`). At the pinned `kuid v0.0.7` it does exist. Do not "upgrade"
  KUID without re-testing kuidapps.
- `kuidapps@0c1a0b2e` and `nokia-srl@f6b92141` both pin `sdcio/config-server v0.0.22`
  [VERIFIED: both `go.mod`]. They write `apiVersion: config.sdcio.dev/v1alpha1`, which **is still served** by
  v0.0.58 (storage is `config`) — so wire compatibility holds — but source compatibility does not
  (`BuildConfig` arity). This is one more reason to own the provider (§6).
- The `Config` CRD's storage version changed to `config`. Any first-party client must not assume
  `v1alpha1` is storage.

**Requirement wording**: FR-017's last sentence ("The image, schema and mapping versions MUST be pinned as
one compatibility set") stands but must name **nine** parts and must forbid a mutable `branch` ref in the
`Schema` CR. `contracts/crd-api.md` §Version contract's "five-part compatibility set" is replaced by the
table above.

---

## 8. RECOMMENDATION — FR-017 / PC-14: the OpenConfig-vs-native register

> **Rewrite FR-017 as native-first. Keep the register (PC-N-12 survives) and invert its default: every path
> is native `srl_nokia` unless an entry records a justified OpenConfig exception. On SR Linux there are
> currently no exceptions, so the register's content is a single global statement plus a per-path coverage
> assertion.**

### The evidence

1. **The sdcio schema for SR Linux is native-only.** `Schema.spec.repositories[].schema.models` is
   `[srl_nokia/models]`; the OpenConfig tree appears only under `includes`, which exists to resolve imports,
   not to define the schema [VERIFIED: both the 24.10.1 and the 25.7.1 Schema CRs]. Therefore **any path
   SDC validates and applies is a native path**, by construction. Rendering OpenConfig would mean either
   adding `openconfig` to `models` (untested by anyone upstream) or bypassing SDC (forbidden by Open
   decision 1).
2. **OpenConfig on SR Linux is a separate, optional management server with a hard prerequisite.**
   `/system/management/openconfig` is a **presence** container gated by `if-feature srl-feat:openconfig`,
   with `admin-state` carrying
   `must "(. = 'disable' or ../../../lldp)"` — *"OpenConfig can only be enabled if the lldp presence
   container is configured"* [VERIFIED: srlinux-yang-models v25.7.1
   `srl_nokia/models/system/srl_nokia-openconfig.yang:39-52`, first-released 22.6.1]. Containerlab does
   enable it for images ≥24.10 (`set / system management openconfig admin-state enable`, plus
   `set / system lldp admin-state enable`) [VERIFIED: containerlab `nodes/srl/version_configs/oc.cfg`,
   `srl_default_config.go.tpl:26`, gated at `version.go:213-227`], so it is *available* in this lab — but it
   is a per-node runtime dependency, not a property of the model.
3. **The gRPC server picks a model set.** `/system/grpc-server[name]/yang-models`, enum `native | openconfig`,
   **default `native`**, described as *"yang-models to be used when origin field is not present in
   requests"* [VERIFIED: `srl_nokia/models/grpc/srl_nokia-grpc.yang:466-476`]. Mixing is possible only by
   setting the gNMI `origin` field per request — which SDC does not expose on `Config.spec.config[].path`
   (a `Config` blob carries a path and a value, no origin) [VERIFIED: parsed Config CRD].
4. **Coverage asymmetry.** v25.7.1 ships **316** `srl_nokia` `.yang` files and **168** `openconfig` files
   [VERIFIED: `find … -name '*.yang' | wc -l` on the v25.7.1 tree], and the OpenConfig tree includes SR
   Linux's own `openconfig-srl-deviations.yang` and `openconfig-srl-augments.yang` — i.e. it is an adapted,
   deviated subset, not a superset.

### Recommended FR-017 wording

> **FR-017**: The provider MUST render device configuration using the **native `srl_nokia` YANG models** that
> the pinned device schema defines, because the pinned schema's model set is native-only and the device's
> OpenConfig surface is an optional, separately-enabled, deviated subset. The platform MUST maintain an
> OpenConfig-versus-native **path register** asserting, per rendered path, which model family was chosen and
> why; the register's default is **native**, and any OpenConfig path MUST carry a recorded justification,
> the device feature it depends on, and the gNMI `origin` it is sent with. CI MUST fail if a rendered path
> is absent from the register, so a new construct cannot pass uncovered. The device image, both YANG
> repository pins, the schema-CR version, the device-configuration release, the fabric and allocation
> releases, containerlab, the metric collector and the mapping version MUST be pinned as one compatibility
> set (§7).

**Consequences**: PC-14 is replaced (its content collapses to "native, always, for this platform").
PC-N-12 survives unchanged — the register's *existence* and its CI guard are still required, and are now the
thing that catches a future engineer reaching for an OpenConfig path because it "looks standard". D-09's
per-path justifications for SONiC (`sonic-acl` not served over gNMI; kernel devices outside the OpenConfig
interface tree) are deleted; the single SR Linux justification replaces them. **Do not delete the register.**
It is cheap, it is the only thing making the model choice auditable, and SR Linux's own `yang-models` leaf
proves the choice is real and per-server.

---

## 9. Kind ↔ containerlab networking, and SR Linux specifics

### 9.1 Reachability

SDC's data-server dials gNMI from a **pod**, not from the node's host network — the
`data-server-controller` StatefulSet declares no `hostNetwork`
[VERIFIED: config-server `artifacts/statefulset-data-server.yaml`, no `hostNetwork` key]. Pod egress to
`172.31.0.0/16` therefore leaves the kind node container, SNAT'd to the node's address on that bridge.

The existing 004/003 design already does the right thing: create an owned, labelled Docker network on
`172.31.0.0/16`, `docker network connect` every kind node container to it, and point containerlab's
`mgmt.network` at it [VERIFIED: /root/agentic-netops/scripts/lib/kind.sh:15-16,39,140;
lab/topology.clab.yml:4]. **Keep this unchanged for SR Linux.** It is strictly better than either sdcio
variant, both of which are also documented upstream:
- sdcio/docs option A: `mgmt.network: kind` — containerlab joins the *kind* bridge
  [VERIFIED: sdcio/docs `docs/examples/1_k8s_srl.md`].
- sdcio/docs option B: a separate clab network plus
  `sudo iptables -I DOCKER-USER -o br-$(docker network inspect -f '{{ printf "%.12s" .ID }}' kind) -j ACCEPT`
  [VERIFIED: `docs/getting-started/basic-usage.md`].

**Carry the `DOCKER-USER` ACCEPT rule into the provisioning script** even with the shared network: Docker's
`DOCKER-USER` chain is consulted for forwarded traffic and a restrictive host policy will otherwise drop
pod→device packets with no useful error. Make it idempotent and remove it on teardown (it is an owned
resource, FR-010).

**PC-A-06 stays intact**: the NetworkPolicy that makes `172.31.0.0/16` unreachable *from the intent tier*
(FR-075/PC-N-01) must continue to deny the tier while permitting `sdc-system`. Only the port in the denial
dial changes: **57400** (gNMI/TLS) instead of SONiC's 9339. Note SR Linux under containerlab **also** exposes
a plaintext gNMI server on **57401** (`grpc-server insecure-mgmt`, `port 57401`, no TLS profile)
[VERIFIED: containerlab `nodes/srl/version_configs/grpc.cfg:10-16`]. **The denial probe and the NetworkPolicy
must cover 57401 as well as 57400**, or the safety boundary has a hole that did not exist on SONiC.

### 9.2 TLS

Containerlab generates a per-lab CA and a per-node certificate and installs them as
`system tls server-profile clab-profile` (pre-26.3) / `system tls profile clab-profile` (≥26.3), with
`authenticate-client false` unless a trust anchor is supplied
[VERIFIED: containerlab `nodes/srl/version_configs/tls{,_pre26_3}.cfg`; `version.go:236-240`]. The
`grpc-server mgmt` instance binds that profile and explicitly `delete`s `default-tls-profile`
[VERIFIED: `version_configs/grpc.cfg:2,8`].

**Recommendation: `skipVerify: true, insecure: false`** — i.e. TLS on the wire, no CA verification. That is
exactly what upstream SDC ships and tests (`TargetConnectionProfile/gnmi-skipverify`, §3.3), and the clab CA
is ephemeral per lab deployment so pinning it would make the lock file lab-run-specific. Record it as a
**documented lab trust boundary** (the plan already has that concept) and note the production alternative:
`DiscoveryRule.spec.targetConnectionProfiles[].tlsSecret` for mTLS with the clab CA mounted
[VERIFIED: parsed DiscoveryRule CRD]. **Do not use `insecure: true` / port 57401** — it would weaken the
boundary for no benefit.

Credentials: a `kubernetes.io/basic-auth` Secret named for the provider,
`admin` / `NokiaSrl1!` [VERIFIED: sdcio/docs `secret-srl.yaml`] — note this is SR Linux's **post-23.10**
default password; it satisfies FR-019's "Secret, never a manifest literal" as long as it is generated or
sourced at provisioning time and never committed.

### 9.3 gNMI server limits — the one real SR Linux operational trap

`/system/grpc-server[name]` defaults [VERIFIED: srlinux-yang-models v25.7.1
`srl_nokia/models/grpc/srl_nokia-grpc.yang:426-455`]:

| Leaf | Default | Meaning |
|---|---|---|
| `rate-limit` | **60** | *"a limit on the number of RPC calls per minute"* |
| `session-limit` | **20** | *"simultaneous active gRPC sessions … in the context of a Subscribe RPC this is the number of simultaneously active SubscribeRequests across all Subscribe RPCs"* |
| `max-concurrent-streams` | 65535 | per-connection HTTP/2 streams (if-feature) |
| `timeout` | 7200 s | idle timeout |
| `metadata-authentication` | true | username/password per request |
| `trace-options` | — | enum `request response stream common grpc` |

Containerlab raises **`rate-limit` to 65000** on both `mgmt` and `insecure-mgmt`, and **enables
`trace-options [ request response common ]`**, but leaves `session-limit` at its default of **20**
[VERIFIED: containerlab `nodes/srl/version_configs/grpc.cfg:1-16` — `session-limit` is absent].

Two concrete obligations for the spec:

1. **Session budget.** SDC's sync profile holds a persistent `get` loop (or an `onChange` Subscribe) per
   target, and gnmic — as the sole device metric collector (FR-088/Rule 9) — holds one or more Subscribe
   streams per target. With `session-limit: 20` and `workers: 10` in the sync profile
   [VERIFIED: `target-sync-profile-gnmi.yaml`], plus a multi-path gnmic subscription, a four-node fabric is
   not at risk but the *shape* is: **every added subscription path consumes a session**. Recommend the
   bring-up phase set `set / system grpc-server mgmt session-limit 0` (0 = unlimited, range 0..65535) or an
   explicit generous value, and that the capability gate (FR-004) **assert the configured
   `rate-limit`/`session-limit`** rather than assume containerlab's defaults. This is a genuinely new
   PC-A-06-adjacent coupling that SONiC did not have.
2. **`trace-options` off in steady state.** Containerlab turns on request/response tracing by default. On a
   4-node lab with a 30 s full-tree `get` sync **plus** gnmic subscriptions this writes a large, continuous
   log volume on the node. Recommend the lab bootstrap clear it
   (`delete / system grpc-server mgmt trace-options`) after bring-up, and that the requirement for
   "bootstrap configuration limited to management and gNMI reachability" (C-02) name this explicitly.

Also note: the container path is `/system/grpc-server[name=…]/gnmi/…` from **24.3 onwards**
(`augment "/srl-system:system" … first-released "24.3.1"` [VERIFIED:
`srl_nokia-grpc.yang:509-514`]); `system gnmi-server` as a top-level container only exists pre-24.3
[VERIFIED: containerlab `version_configs/grpc_pre24_3.cfg`, gated at `version.go:205-209`]. Any requirement
text that says "`system gnmi-server` settings" is wrong for the pinned 25.7.1 image. Per-server gNMI options
that matter: `commit-confirmed-timeout` (default 0 = off) and `commit-save` (default false)
[VERIFIED: `srl_nokia-gnmi.yang:84-104`] — `commit-confirmed-timeout` is worth considering as defence in
depth behind SDC's own `TransactionConfirm`.

### 9.4 Two sizing facts for the fabric spec

- ACL binding is **per sub-interface per direction**, `input`/`output`, `max-elements 4`, `ordered-by user`,
  with the model note *"On 7220 and 7250 IXR platforms only a single MAC, IPv4 or IPv6 filter is
  supported"* [VERIFIED: `srl_nokia-acl.yang:1819-1900`]. The containerlab default SRL type is `ixr-d3`
  (a 7220 IXR-D3) [VERIFIED: sdcio's and kubenet's clab files both use `type: ixr-d3`/`ixrd3`], so it is
  **one filter per type per direction per sub-interface**. This settles Open decision 4's binding-point
  question: the unit of exclusivity is *(sub-interface, direction, filter-type)*, not *(port, stage)*.
  Filters are keyed `name` + `type` where `type` ∈ `{ipv4, ipv6, mac}` (mac is platform-gated)
  [VERIFIED: `srl_nokia-acl.yang:1926-1945`]. Detailed ACL work belongs to the ACL research agent; this is
  recorded because §6's ownership analysis depends on it.
- Containerlab pre-seeds `/acl/acl-filter[name=cpm]` entries 88, 98, 158 (ipv4) and 128, 138, 188 (ipv6)
  [VERIFIED: `nodes/srl/version_configs/acl.cfg`]. **The platform must never own the `cpm` filter**, and any
  read-back check must be scoped by filter name — the precise failure R-26 recorded on SONiC (a check that
  passes on a stock device) has an SR Linux analogue waiting.

---

## 10. Requirement-level change list (summary)

| Artefact | Action |
|---|---|
| `platform-coupling.md` §Recorded divergence | **Delete** (§5) |
| PC-01 | **Replace** with the nine-part set (§7) |
| PC-11, PC-12, PC-13, PC-16 (2nd half) | **Delete** (§5) |
| PC-14 | **Replace** with "native-first, register retained, default inverted" (§8) |
| PC-N-07, PC-N-12, PC-N-13, PC-N-01 | **Survive**; PC-N-13 gains `ConfigBlame`/`RunningConfig` as its instruments; PC-N-01's denial dial gains port **57401** (§9.1) |
| PC-A-02 | **Rewrite**: binding unit is (sub-interface, direction, filter-type) (§9.4) |
| PC-A-06 | **Rewrite**: ports 57400 **and** 57401; mgmt CIDR unchanged |
| FR-013 | **Reword** (§6): reuse upstream device-configuration and allocation APIs unchanged; extend the fabric intent in exactly one first-party object where upstream is not expressive enough |
| FR-014 | **Survives as a requirement** under option (b): a first-party SR Linux provider renders deterministic `config.sdcio.dev/Config` objects (§6) |
| FR-015 | **Make concrete**: `Config.spec` / `status.appliedConfig` / `RunningConfig` / `Deviation{UNHANDLED,NOT_APPLIED,OVERRULED}`; `REVERTIVE` + `spec.revertive` (§3.4) |
| FR-016 | Add: **no non-deterministic identifier generation** (upstream's `math/rand` system-ID is the counter-example) (§2.1) |
| FR-017 | **Rewrite** native-first (§8) |
| FR-042 | **Rewrite**: two-sided read-back = `status.appliedConfig` + `ConfigBlame`/`RunningConfig`, scoped by intent, never by "any entry on the device" |
| FR-060 / PC-N-07 | **Survives literally** only under option (b)+R1; it is what rules option (c) out (§6) |
| FR-062 | Add: upstream allocates **only IP and AS**; VNI/VLAN/RT/RD allocation is first-party (§1.4, §4) |
| FR-065 / CR-004 | **Reword "server-side dry-run"** — the API server does not validate the Config payload; the real gate is `TransactionSet{DryRun:true}` or `sdc-lite config validate` (§3.5) |
| `contracts/kuid-claim-profiles.md` §1 | **Rewrite**: `vxlan.be.kuid.dev/VXLANIndex` for VNIs (with `genid`/32-bit as the recorded fallback); `extcomm` index takes `type`/`subType`/`globalID`; `vlan` index takes `minID`/`maxID` (§4) |
| `contracts/network-spec.md` | **Rewrite §1** around the first-party fabric-intent object of §6-R1, with an explicit mapping table to `network.app.kuid.dev/Network` for the fabric half (§1.3) |
| `contracts/crd-api.md` §Version contract | **Replace** the five-part set; add cert-manager as a pinned prerequisite; forbid mutable `branch` refs in the `Schema` CR |
| `contracts/reconciliation.md` Rule 5 | Remove the divergence footnote; direct device mutation is now simply forbidden and nothing does it |
| `contracts/reconciliation.md` Rule 4 + Contract tests | Replace "no whole-config write" with the `ConfigBlame`/`OVERRULED`-is-terminal ownership assertion (§6) |
| C-08 / plan §Technical Context | Delete `cmd/fabric-executor`, `pkg/fabricplan`'s raw-store half, `pkg/sdc/offline.go`'s SONiC assumptions |
| D-04, D-05, D-06, D-09, D-12 | D-12 **deleted**; D-04 gains the version-skew finding as evidence; D-05 gains the "SDC was never actually deployed" correction; D-06's stated gap **inverts and then re-opens** (upstream ships a provider, but a dormant, incomplete, buggy one — §6); D-09 **rewritten** as §8 |

---

## Appendix — repositories read this session

Shallow clones (`git clone --depth 1`), all read directly:
`kubenet-dev/{kubenet, apis, docs, examples, kubenetctl, kubenet-choreo}`,
`kuidio/{kuid, kuidapps, nokia-srl, docs}`,
`sdcio/{config-server, data-server, docs, integration-tests, schema-server, sdc-lite}`,
`nokia/srlinux-yang-models` (tag `v25.7.1`), `sdcio/srlinux-yang-patch`,
`srl-labs/containerlab` (sparse `nodes/srl`).
Local read-only: `/root/agentic-netops` (`versions.lock.yaml`, `deploy/{kubenet,kuid,sdc}`, `pkg/kubenet`,
`pkg/render`, `pkg/fabricplan`, `api/`), `/root/learn-srlinux/docs`,
`/root/agentic-netops-srl/specs/004-agentic-netops-composite/{spec,plan,research,platform-coupling}.md` and
`contracts/{crd-api,reconciliation,network-spec,kuid-claim-profiles}.md`.
Registry: ghcr.io anonymous manifest HEADs for every digest quoted in §7.
