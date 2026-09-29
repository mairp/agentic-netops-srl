# 01 — Nokia SR Linux as the containerlab lab platform

**Topic**: replaces couplings PC-01, PC-02, PC-03, PC-18, PC-19, PC-A-01, PC-A-03, PC-A-06, PC-A-13
**Date**: 2026-09-20 | **Author**: research agent | **Host**: mairp (22 vCPU, 93 GB, kernel 7.0.14-15-pve)

## Evidence tags

Every claim below carries one of:

- `[LAB]` — **measured this session** on live SR Linux containers I deployed and tore down
  (`ghcr.io/nokia/srlinux@sha256:0096fe…`, reporting `v26.7.2-519-g94fbd638fa8`, containerlab
  0.79.0, gnmic 0.47.0). Labs `typeprobe`, `evpnmtu`, `netreuse` — all destroyed.
- `[VERIFIED: <path|url>]` — read in a primary source this session.
- `[UNVERIFIED: from memory]` — could not confirm.

Host tooling confirmed this session: `containerlab version` → **0.79.0**, commit `5ae50094a`,
2026-08-21; `gnmic version` → **0.47.0**; docker server **26.1.5+dfsg1**; `skopeo`,
`docker buildx v0.17.1` present; `/dev/kvm` present; `ssse3` present in `/proc/cpuinfo`; 22 cores,
93 GB RAM. `[LAB]`

---

## 0. Executive summary and the decisions this forces

| # | Question | Recommendation |
|---|---|---|
| 1 | Image / pin | `ghcr.io/nokia/srlinux` kind `nokia_srlinux`. **Pin `25.7.1` if SDC/sdcio is the schema authority; otherwise pin `26.7.2`.** Digests in §1.4 |
| 2 | Node types | **leaf = `ixr-d2l`, spine = `ixr-d3l`.** Both license-free, both carry full EVPN-VXLAN. `ixr-h*` (except H5) has **no VXLAN at all** |
| 3 | Interfaces | `ethernet-1/N` on-device, `e1-N` in Linux, both accepted by containerlab. Concrete map in §3.5 |
| 4 | Management | gNMI/TLS **57400**, insecure gNMI **57401**, JSON-RPC 80/443, NETCONF 830, SSH 22. TLS profile `clab-profile`. Pre-created Docker network **is** reused; `mgmt-ipv4` works. §4 |
| 5 | Host reqs | **No KVM, no nested virt.** SSSE3 + kernel ≥ 4.10. ~1.4–1.8 GiB RSS/node idle. **PC-03's two-profile split collapses to one profile**; NFR-004 rewrite in §5.4 |
| 6 | Config | gNMI Set writes **running only**. Persist with `/system/configuration/auto-save`. Commit-confirmed works over gNMI. §6 |
| 7 | Capability gate | Runnable `gnmic` checklist in §7 |
| 8 | MTU | **9412 underlay port MTU (7220 IXR hard max), 9348 inner IP MTU, 9320 v4 / 9300 v6 ping payload — all measured on the wire.** Constitution's 9216/9166/9162 must be replaced. §8 |
| 9 | Container limits | Dataplane ceiling ≈ **5 kpps/node**. ACLs *are* enforced and counters *do* work. §9 |
| 10 | Legal | Freely pullable, no registration, BSD-3 repo, "learning, demo, test and CI". §10 |

**Three findings that change requirement wording, not just values:**

1. **SRv6 is unavailable on every license-free datacenter type.** `system features` contains no
   `srv6`, `srv6-dt2`, `srv6-usid-basic` or `mpls` on `ixr-d2l`/`d3l`/`d5`/`h4`. `[LAB]` Nokia's
   26.7 SRv6 guide restricts SRv6 to 7730 SXR, 7220 IXR-H5 and IXR-H6 — and H5 has only *"basic
   SRv6 support … primarily function as pure transit nodes for uSID"*, while H6 needs a license.
   This is decisive input for **spec §Open decisions 3** (see §2.4).
2. **ACLs bind to a *subinterface*, not a port** — `/acl/interface[interface-id=…]/interface-ref/{interface,subinterface}`
   with `input`/`output` containers. This rewrites **PC-A-02 / FR-037 / FR-043** exactly as
   **spec §Open decisions 4** anticipated (see §2.5).
3. **The constitution's MTU numbers are wrong for SR Linux by construction**, not just by value:
   they count the inner *Ethernet frame*, and SR Linux has no IPv6 VXLAN underlay to give a
   "9162 v6" number to. §8.

---

## 1. Kind, image, tags, pinning

### 1.1 Kind

`kind: nokia_srlinux` (long form) or `kind: srl` (short form) — both registered.
`[VERIFIED: scratchpad/containerlab/nodes/srl/srl.go:50-51,63]`

```go
srlShortPlatformName = "srl"
srlLongPlatformName  = "nokia_srlinux"
kindNames = []string{srlShortPlatformName, srlLongPlatformName}
```

Use the long form; it is what containerlab's own docs and every current srl-labs topology use.
`[VERIFIED: containerlab/docs/manual/kinds/srl.md]`

### 1.2 Registry

`ghcr.io/nokia/srlinux`. *"Everyone can pull SR Linux container from a public registry"*
`[VERIFIED: containerlab/docs/manual/kinds/srl.md:17-22]`. Tags "match the released version and are
listed in the [srlinux-container-image] repo".

### 1.3 Tags available as of 2026-09-20

`skopeo list-tags docker://ghcr.io/nokia/srlinux` returned 178 tags `[LAB]`. Recent trains:

| Train | Latest patch tag | Also `-arm64`/`-amd64` variants |
|---|---|---|
| 26.7 | **`26.7.2-519`** (= `26.7.2` = `26.7` = `latest`) | yes |
| 26.3 | `26.3.3-392` | yes |
| 25.10 | `25.10.5-111` | yes |
| 25.7 | `25.7.2-266` | yes |
| 25.3 | `25.3.3-158` | yes |
| 24.10 | `24.10.7-191` | yes |
| 23.10 | `23.10.8-54` | no |

`latest` currently resolves to the same manifest list as `26.7.2`. `[LAB]` **NFR-003 forbids
`latest`** — never reference it.

### 1.4 Digests (manifest-list, multi-arch) — verified this session `[LAB]`

| Tag | Manifest-list digest (pin this) | Created |
|---|---|---|
| `26.7.2` | `sha256:0096fe3ebcafabb7253492e2060425fe027a168e0e066766d1e85efbb0b48be8` | 2026-08-19 |
| `26.7.1` | `sha256:2c9318fa3bcbc7667198e9c4cb268864cb287409e89eef2768f06cfadda6a6a3` | — |
| `26.3.3` | `sha256:85c90ce308ebe1cce69f27461e9eacae684eaccf08b0c6e29459739d49793c8e` | 2026-06-24 |
| `25.10.5` | `sha256:810076059c7ad1ba6e6556e6a7e06844eff8ade25eeced48e2ff20dcb9c6c091` | 2026-07-23 |
| `25.7.2` | `sha256:5b5b87c9730fa21a8fac827f1527961c61e79c212e793dfe72520e0b61e4335f` | — |
| **`25.7.1`** | **`sha256:6ab1250cbff4b536e0996e57d2d9c2a7bf3154028c21e4c978e13254add3c402`** | 2025-08-19 |

Per-arch child digests for `26.7.2`: `linux/amd64` =
`sha256:38177562d8218899acd01ed2ca2356a2628ca2b7ab86ca9dc638b7c0725ef9e7`, `linux/arm64` =
`sha256:43b3579df34ced58c722028b7287b0108ead1310d460d70eb4734d4293c7cd7f`. `[LAB]`

Image is **one layer, 753 MB compressed / 2.35 GB on disk**. `[LAB]`

### 1.5 How to obtain and pin a digest

Three methods, all verified this session `[LAB]`:

```bash
# 1. docker buildx (already installed) — prints the manifest-list digest and both arch children
docker buildx imagetools inspect ghcr.io/nokia/srlinux:26.7.2
#   Digest:    sha256:0096fe3ebcafabb7253492e2060425fe027a168e0e066766d1e85efbb0b48be8
#   Manifests: …@sha256:3817…  linux/amd64
#              …@sha256:43b3…  linux/arm64

# 2. skopeo — raw manifest, hash it yourself (this is the canonical definition of the digest)
skopeo inspect --raw docker://ghcr.io/nokia/srlinux:26.7.2 | sha256sum
#   0096fe3ebcafabb7253492e2060425fe027a168e0e066766d1e85efbb0b48be8

# 3. skopeo structured (careful: this resolves the *list* digest, not the per-arch one)
skopeo inspect docker://ghcr.io/nokia/srlinux:26.7.2 | jq -r '.Digest, .Created'
```

**Pin the manifest-list digest, not the amd64 child.** Both are immutable; the list digest keeps
the lab portable to an arm64 host (Nokia has shipped native arm64 since 24.10.1, still labelled
*preview* `[VERIFIED: containerlab/docs/manual/kinds/srl.md:26-34]`). Containerlab accepts
`image: ghcr.io/nokia/srlinux@sha256:0096fe…` directly and resolves the right arch — verified by
deploying four nodes that way. `[LAB]`

There is **no separate registry auth**: `skopeo`/`docker pull` worked anonymously. `[LAB]`

### 1.6 Which single release to pin — recommendation

The binding constraint is **not** SR Linux and **not** containerlab; it is **sdcio**.

- containerlab 0.79.0 handles 26.7.2 correctly, including the 26.3+ `system tls profile` rename
  (it selects `tls.cfg` vs `tls_pre26_3.cfg` at `v26.3`)
  `[VERIFIED: containerlab/nodes/srl/version.go:235-239]`; verified live on 26.7.2 `[LAB]`.
- `nokia/srlinux-yang-models` has tags through **`v26.7.2`** `[LAB: git ls-remote]`.
- **sdcio publishes `Schema` CRs only up to `nokia_srl` 25.7.1**, and
  `sdcio/srlinux-yang-patch` (the deviations repo the Schema CR references) has branches only
  `main, v24.7, v24.10, v24.10system0prefixcount, v25.3, v25.7` — with `v25.3` and `v25.7`
  pointing at the *same* SHA as `v24.10`.
  `[VERIFIED: raw.githubusercontent.com/sdcio/integration-tests/main/tests/01-crs/schema/schema-nokia-srl-25.7.1.yaml; api.github.com/repos/sdcio/srlinux-yang-patch/git/refs/heads]`
- kubenet targets 24.3.2 / 24.7.2 and its published Schema CR points at the **deleted**
  `github.com/sdcio/yang` repo — it is broken and must not be copied.
  `[VERIFIED: kubenet-dev/kubenet@v0.0.1 sdc/schemas/srl24-3-2.yaml; api.github.com/repos/sdcio/yang → 404]`

**Recommendation — pin `25.7.1` at `sha256:6ab1250cbff4b536e0996e57d2d9c2a7bf3154028c21e4c978e13254add3c402`.**

Why: it is the newest SR Linux release for which *every* toolchain component has a published,
matching artifact — containerlab kind support, a `v25.7.1` YANG tag, an sdcio `Schema` CR
(`srl.nokia.sdcio.dev-25.7.1`), and a matching `srlinux-yang-patch` deviations branch (`v25.7`).
It is also what sdcio's own CI lab runs (`ghcr.io/nokia/srlinux:25.7.1`)
`[VERIFIED: raw.githubusercontent.com/sdcio/integration-tests/main/containerlab/citest.clab.yml]`.

**Alternative — `26.7.2`** if the retarget decides SDC is *not* the schema authority (spec §Open
decisions 1/2 resolved toward a first-party gNMI provider). Everything in §2–§9 of this report was
measured on 26.7.2 and works. The extra cost is one hand-authored `Schema` CR (the 25.7.1 shape
works verbatim with `version: 26.7.2` / `ref: v26.7.2`) and either dropping the deviations entry or
forking `v25.7` — non-trivial risk, because the deviations exist precisely so Nokia's raw YANG
compiles in sdcio.

**Do not pin a train older than 25.3**: `system-filter`, `netconf` (24.7+), the `grpc-server`
container (24.3+) and the containerlab CPM ACL injection (24.3+) all post-date it, and the
capability gate in §7 assumes them.

### 1.7 What replaces PC-01's "five-part compatibility set"

| SONiC slot | SR Linux replacement |
|---|---|
| Device image + digest | `ghcr.io/nokia/srlinux@sha256:6ab1250…` (`25.7.1`) |
| YANG schema commit | `github.com/nokia/srlinux-yang-models` tag `v25.7.1` — *the same tag string as the image release*, which is a real simplification over SONiC |
| Mapping version | sdcio `Schema` CR `srl.nokia.sdcio.dev-25.7.1` + `srlinux-yang-patch` branch `v25.7` |
| Containerlab version | `0.79.0` (already pinned) |
| Routing stack | **deleted** — SR Linux has no FRR. PC-17 (the FRR 10.3 IPv6 IRB Type-5 defect) has **no successor**; drop it, do not translate it |

---

## 2. Node `type` values, licensing, and feature differences

### 2.1 The full type list (containerlab 0.79.0)

`[VERIFIED: containerlab/nodes/srl/srl.go srlTypes map; containerlab/docs/manual/kinds/srl.md:180-190]`

- **7215 IXS**: `ixs-a1`
- **7220 IXR**: `ixr-d1`, `ixr-d2`, `ixr-d3`, `ixr-d2l`, `ixr-d3l`, `ixr-d4`, `ixr-d5`, `ixr-h2`,
  `ixr-h3`, `ixr-h4`, `ixr-h4-32d`, `ixr-h5-32d`, `ixr-h5-64d`, `ixr-h5-64o`, `ixr-h6`
- **7250 IXR**: `ixr-6`, `ixr-6e`, `ixr-10`, `ixr-10e`, `ixr-18e`, `ixr-x1b`, `ixr-x3b`,
  `ixr-x4` (alias `ixr-x4-d`)
- **7730 SXR**: `sxr-1x-44s`, `sxr-1d-32d`, `sxr-1-32d`

Default when `type:` is omitted: **`ixr-d2l`**
(`SRLinuxDefaultType = "ixr-d2l"` `[VERIFIED: srl.go:33]`).

Hyphenless aliases (`ixrd2l`, `ixrh432d`, `ixr6e`, …) exist but are **deprecated**: containerlab
logs *"Deprecated type format will be removed after January 2026"* `[VERIFIED: srl.go:218-230]`.
**Use the hyphenated form.**

`ixr-6e` / `ixr-10e` get `SRL_CHASSIS_MODE=GEN2CP_ONLY` injected automatically
`[VERIFIED: srl.go:302-308]`.

### 2.2 Port inventory, measured `[LAB]`

Booted on 26.7.2 and read with `sr_cli -d 'show interface brief'`:

| type | `ethernet-1/N` count | Layout |
|---|---|---|
| **`ixr-d2l`** | **58** | `1/1–1/48` = 25G, `1/49–1/56` = 100G, `1/57–1/58` = 10G |
| **`ixr-d3l`** | **34** | `1/1–1/32` = 100G, `1/33–1/34` = 10G |
| **`ixr-d5`** | **34** | `1/1–1/32` = 400G, `1/33–1/34` = 10G |
| **`ixr-h4`** | **66** | `1/1–1/64` = 400G, `1/65–1/66` = 10G |

Corroborated for the rest of the family by a parallel probe on the same image (`ixr-d1` 52 =
48×1G + 4×10G; `ixr-d2` 56 = 48×25G + 8×100G; `ixr-d3` **34 = 1/1–1/2 @10G then 1/3–1/34 @100G**;
`ixr-d4` 36; `ixr-h2` 128×100G; `ixr-h3` 34 with 10G *first*; `ixs-a1` 52). `[LAB, parallel probe]`

**Trap worth writing into the topology comments**: on `ixr-d3` and `ixr-h3` the two 10G SFP+ ports
are **first** (`1/1`, `1/2`); on `ixr-d2l`, `ixr-d3l`, `ixr-d5`, `ixr-h4` they are **last**.
learn-srlinux's own `evpn01.clab.yml` wires `spine1:e1-1`/`e1-2` on an `ixr-d3`, i.e. onto the 10G
ports. `[VERIFIED: /root/learn-srlinux/labs/evpn01.clab.yml]` Harmless in the container (a 100G↔400G
link came up fine `[LAB]`) but confusing in a reference topology.

### 2.3 Licensing per type

Containerlab's statement, verbatim
`[VERIFIED: containerlab/docs/manual/kinds/srl.md:413-416]`:

> SR Linux container can run without a license emulating the datacenter types (7220 IXR).
> In that license-less mode, the datapath is limited to 1000 PPS and the `sr_linux` process will
> restart once a week.
> The license file lifts these limitations as well as unlocks chassis-based platform variants and a
> path to it can be provided with `license` directive.

Measured boot behaviour on 26.7.2 with **no** `license:` `[LAB, parallel probe]`:

- **Run license-free**: `ixs-a1`, `ixr-d1`, `d2`, `d2l`, `d3`, `d3l`, `d4`, `d5`, `h2`, `h3`,
  `h4`, `h4-32d`, `h5-32d`, `h5-64d`, `h5-64o`.
- **Exit(0) ~60 s after start**: `ixr-6e`, `ixr-10e`, `ixr-18e`, `ixr-x1b`, `ixr-x3b`, `ixr-x4`,
  `sxr-1x-44s`, `sxr-1d-32d`, `sxr-1-32d`, **and `ixr-h6`**.

So "all 7220 IXR are free" is *not* strictly true — **H6 needs a license**. And 7215 IXS-A1, which
containerlab's wording leaves ambiguous, *is* free.

learn-srlinux confirms the licensed side: *"MPLS features are currently … supported only on SR Linux
7250 IXR-6e/10e and 7730 SXR platforms. Container images emulating these platforms require a license
to operate."*
`[VERIFIED: /root/learn-srlinux/docs/tutorials/mpls/mpls-ldp/intro.md:25]`

License file is mounted at `/opt/srlinux/etc/license.key:ro` from `<labdir>/license.key`
`[VERIFIED: srl.go:260-265]`.

### 2.4 Feature availability by emulated type — the decisive table

Read from `info from state system features` on live nodes, 26.7.2. `[LAB]`

| feature | `d2l` | `d3l` | `d5` | `h4` | `h5-*` |
|---|---|---|---|---|---|
| `vxlan` | **YES** | **YES** | **YES** | — | YES |
| `evpn-vxlan-mac-vrf` (L2 VNI) | **YES** | **YES** | **YES** | — | YES |
| `evpn-vxlan-ifl` (L3 VNI / ip-vrf) | **YES** | **YES** | **YES** | — | YES |
| `vxlan-v6` (IPv6 VXLAN underlay) | — | — | — | — | — |
| `evpn-mh` (ESI-LAG / multihoming) | **YES** | **YES** | **YES** | — | — |
| `srv6`, `srv6-dt2` | — | — | — | — | — |
| `srv6-usid-basic` | — | — | — | — | **YES** |
| `mpls` | — | — | — | — | — |
| `acl-filter-mac` | **YES** | **YES** | **YES** | — | — |
| `egress-mac-filter-restriction` | **YES** | **YES** | **YES** | — | — |
| `acl-if-output-shared-tcam-entries` | **YES** | **YES** | **YES** | **YES** | — |
| `acl-subinterface-entry-statistics` | **YES** | **YES** | **YES** | **YES** | — |
| `vxlan-stats` | **YES** | **YES** | — | — | — |
| `warm-reboot` | **YES** | **YES** | — | — | — |
| `openconfig` | **YES** | **YES** | **YES** | **YES** | — |
| `config-sub-if-l2-mtu` | **YES** | **YES** | **YES** | — | — |
| `platform-*` identity | `platform-7220-d2` | `platform-7220-d3` | `platform-7220-d5` | `platform-7220-h4` | — |
| total feature count | 344 | 345 | 355 | 271 | — |

(`h5-*` column is from the parallel probe, not my own run — flagged as such.)

The YANG enforcement point is explicit
`[VERIFIED: scratchpad/yang/srlinux-yang-models/srl_nokia/models/tunnel/srl_nokia-tunnel-interfaces.yang:125-137]`:

```yang
leaf type { mandatory true; type identityref { base srl_nokia-if:si-type; }
  must ".='srl_nokia-if:bridged' or .='srl_nokia-if:routed'" { error-message "unsupported type."; }
  must "not(.='srl_nokia-if:bridged')" { error-message "unsupported type.";
        srl_nokia-ext:if-feature "not srl_nokia-feat:evpn-vxlan-mac-vrf"; }
  must "not(.='srl_nokia-if:routed')"  { error-message "unsupported type.";
        srl_nokia-ext:if-feature "not srl_nokia-feat:evpn-vxlan-ifl"; } }
```

**Consequences for the spec:**

- **`ixr-h*` (except H5) cannot be a leaf or a spine in an EVPN-VXLAN fabric.** Neither can
  `ixr-d1` or `ixs-a1`.
- **SRv6 is dead on the license-free datacenter types.** Nokia's own 26.7 SRv6 guide:
  *"SRv6 is supported on the following platforms: 7730 SXR, 7220 IXR-H5, 7220 IXR-H6. Note: The
  7220 IXR-H5/H6 platforms provide basic SRv6 support … They primarily function as pure transit
  nodes for uSID data traffic."* `[VERIFIED via parallel probe: documentation.nokia.com SR Linux
  R26.7 SRv6 guide]` H5 is free but **transit-only** — no headend `H.Encaps.Red`, no `End.DT46`
  endpoint termination. H6 and SXR need a license, and H6/SXR also have no `evpn-vxlan-*`
  (H6 untested — could not boot).
  **There is no containerlab type on which both EVPN-VXLAN and SRv6 services can be demonstrated.**
  This answers **spec §Open decisions 3** decisively: *drop SRv6 to a future feature, or
  demote it behind a capability gate that will never pass on this lab.* PC-04 and PC-05 have no
  SR Linux successor; FR-005, FR-021–FR-023, SC-009, SC-010, US3 and `SRv6Service` lose their
  substrate. **Do not spend effort "retargeting" them.**
- **`vxlan-v6` is absent on every 7220 IXR type.** The only place it is referenced in the whole
  model tree is one `must` on the bgp-evpn next-hop:
  `must "(../../../encapsulation-type != 'vxlan') or (not(contains(., ':')) and not(. = 'use-system-ipv6-address'))"`
  with `if-feature "not srl_nokia-feat:vxlan-v6"`, error *"IPv6 next-hop address is not supported
  when encapsulation-type is vxlan"*
  `[VERIFIED: …/network-instance/srl_nokia-bgp-evpn.yang:493-501]`. Independently, the
  vxlan-interface egress source-ip is a union whose only enum is `use-system-ipv4-address`
  `[VERIFIED: …/tunnel/srl_nokia-tunnel-interfaces.yang:176-190]`.
  **The VXLAN underlay is IPv4-only.** (The spec's Assumptions already scope out "IPv6 VXLAN
  VTEPs" — this makes it a platform fact rather than a scoping choice.)

### 2.5 ACL model — binding point, egress restrictions, TCAM

**Binding is to a subinterface, not a port.**
`[VERIFIED: …/acl/srl_nokia-acl.yang:2482-2640]`

```yang
list interface { key "interface-id"; max-elements 16383;
  leaf interface-id { type srl_nokia-comm:name; }
  container interface-ref {
    leaf interface    { type leafref { path "/srl_nokia-if:interface/srl_nokia-if:name"; } }
    leaf subinterface { type leafref { path "…/srl_nokia-if:subinterface/srl_nokia-if:index"; }
      must "… type = 'bridged' or … type = 'routed' or …" {
        error-message "ACL allowed with subinterface type bridged or routed"; }
      must "not(starts-with(../interface,'lo'))" {
        error-message "IP ACLs not allowed on loopback subinterface"; } } }
  container input  { list acl-filter { key "name type"; max-elements 4; ordered-by user; … } }
  container output { if-feature "not srl_nokia-feat:platform-7215-a1";
                     list acl-filter { key "name type"; max-elements 4; ordered-by user; … } } }
```

This is exactly the case **spec §Open decisions 4** flagged. FR-037 ("port binding is the only
binding point") and FR-043 (conflict rule in terms of "a port at a stage") **must both be rewritten
in terms of a subinterface at a stage.** The natural unit is the `interface-id` key, which by
convention is the `<interface>.<index>` string (`ethernet-1/1.0`) — verified working `[LAB]`.

**Egress `subinterface-specific` restriction — does NOT apply on 7220 IXR.** The YANG `must`

```yang
must "…/subinterface-specific = 'output-only' or …= 'input-and-output'" {
  srl_nokia-ext:if-feature "not srl_nokia-features:acl-if-output-shared-tcam-entries";
  error-message "On the current platform, subinterface-specific must be set to output-only or
                 input-and-output for egress filters."; }
```
`[VERIFIED: srl_nokia-acl.yang:2604-2612]` is gated on **`not`** the feature — and
`acl-if-output-shared-tcam-entries` is present on d2l/d3l/d5/h4. `[LAB]` I committed an egress IPv4
filter on `ethernet-1/1.0` with `subinterface-specific` left at its default `disabled` and it
applied and **enforced traffic**. `[LAB]` See §9.2.

**`egress-mac-filtering` is required for egress MAC ACLs on the D-series.**
`/acl/egress-mac-filtering` (boolean, default `false`) exists only where
`egress-mac-filter-restriction` is set, i.e. d2/d2l/d3/d3l/d4/d5. Setting it `true` caps egress ACL
*instances* at 32 IPv4 / 32 IPv6 / 32 MAC. `[VERIFIED: srl_nokia-acl.yang:2756-2771]`

**One filter per subinterface per direction.** Despite `max-elements 4`, the platform enforces a
server-side limit; the exact error string on 7220 IXR is
`Exceeding maximum filters under a single subinterface on this platform. Maximum limit 1.`
`[LAB, parallel probe]` A MAC filter combined with an IP filter in the same direction fails with
`This platform does not support the usage of MAC filter in combination with IPv4/IPv6 filter in the same direction.`
`[LAB, parallel probe]`

**Key/name/priority ranges — the PC-06/PC-09 successors:**

| SONiC (PC-06..PC-09) | SR Linux equivalent |
|---|---|
| `sonic-acl.yang` name pattern `[a-zA-Z0-9]{1}([-a-zA-Z0-9_]{1,63})`, 2–64 chars | `srl_nokia-comm:name` = `alphanumeric` with length `1..255`, pattern `[A-Za-z0-9!@#$%^&()\|+=`~.,/_:;?-][A-Za-z0-9 !@#$%^&()\|+=`~.,/_:;?-]*` — **much more permissive; the derived-name function from D-13 is no longer forced by the platform** `[VERIFIED: …/common/srl_nokia-common.yang:1279-1309]` |
| `ACL_TABLE.type` enum `MIRROR/MIRRORV6/L3/L3V6` (no L2) | `/acl/acl-filter/type` enum **`ipv4` (1), `ipv6` (2), `mac` (3)** — `mac` gated on `acl-filter-mac`. **A MAC/L2 filter type now exists** on the D-series, so PC-07's refusal disappears `[VERIFIED: srl_nokia-acl.yang:2654-2678]` |
| `IP_PROTOCOL` range excluding 58 (no ICMPv6) | SR Linux has `match ipv6 next-header` with a full protocol set including ICMPv6 — **PC-08's ICMPv6 refusal disappears**; containerlab's own CPM rules use `match ipv6 next-header tcp` `[VERIFIED: containerlab/nodes/srl/version_configs/acl.cfg]` |
| Priority 1 reserved, usable 2–65535 | `/acl/acl-filter/entry/sequence-id` **`uint32` range `0..65535`**, "lower numbered entries are evaluated before higher numbered" — nothing is reserved. PC-N-05's platform-relative wording still holds; the *number* changes to 0 `[VERIFIED: srl_nokia-acl.yang:2418-2428]` |
| `ACL_TABLE` has no priority leaf → two lists on one port must be refused (PC-10) | `input`/`output` lists are `ordered-by user` with an explicit evaluation order — but the platform caps them at 1 per type per direction anyway, so **the refusal survives for a different reason** |

**TCAM / instance scale (idle, free counts)** `[LAB, parallel probe]`:
`ixr-d2l`: `input-ipv4-filter-instances-routed` 63, **`…-bridged` 7**; TCAM `if-input-ipv4` 6912,
`if-input-ipv6` 2304, `if-input-mac` 2304, `if-output-cpm-ipv4` 1536, `if-output-cpm-ipv6` 512.
`ixr-d5`: `if-input-ipv4` 8192, `if-input-ipv6` 6144, `if-input-mac` 8192.
`ixr-h4`: `if-input-ipv4` **512**. The **bridged instance pool of 7 on Trident3** is the tightest
number for a mac-vrf-heavy lab.

### 2.6 Type recommendation

**`leaf01`, `leaf02` → `ixr-d2l`; `spine01`, `spine02` → `ixr-d3l`.**

Rationale:
- Both license-free; both carry `vxlan` + `evpn-vxlan-mac-vrf` + `evpn-vxlan-ifl` + `acl-filter-mac`
  + `egress-mac-filter-restriction` + `evpn-mh` + `vxlan-stats`. `[LAB]`
- `ixr-d2l` is containerlab's default type and the de-facto leaf in every modern srl-labs
  reference lab. `ixr-d3l` is the matching spine and, unlike `ixr-d3`, has its 100G ports at
  `1/1–1/32`. `[LAB + VERIFIED: srl-telemetry-lab, srl-l3evpn-tutorial-lab, containerlab clos01]`
- `ixr-d2l` gives 48 access ports at `1/1–1/48` and 8 uplinks at `1/49–1/56` — room for the two
  EVPN clients plus the two extra endpoints without renumbering.
- `vxlan-stats` (present on d2l/d3l, **absent on d5**) matters for FR-089 telemetry.

Published reference labs for the record `[VERIFIED: /root/learn-srlinux/labs/evpn01.clab.yml and
parallel probe of srl-labs repos]`:

| Lab | leaf | spine |
|---|---|---|
| learn-srlinux `evpn01` | `ixr-d2` | `ixr-d3` |
| `srl-labs/srl-telemetry-lab` (2 spine / 3 leaf) | `ixr-d2l` | `ixr-d3l` |
| `srl-labs/srl-l3evpn-tutorial-lab` | `ixr-d2l` | `ixr-d3l` |
| containerlab `lab-examples/clos01` | `ixr-d2l` | `ixr-d3l` |
| `srl-labs/nokia-evpn-lab` (2 spine / 4 leaf) | `ixrd2` | `ixrd3` |

---

## 3. Interface naming and the concrete map (replaces PC-A-01)

### 3.1 Naming

`[VERIFIED: containerlab/docs/manual/kinds/srl.md:126-176; srl.go:36,152-156]`

- **On-device / in YANG**: `ethernet-<slot>/<port>`, e.g. `ethernet-1/1`. Slot is always `1` —
  containerlab emulates a single line card.
- **In the Linux namespace**: `e<slot>-<port>`, e.g. `e1-1`. Generation format is `e1-%d`.
- **Both forms are accepted in `links:`.** Verified by deploying a topology with
  `[d3l:ethernet-1/1, d5:ethernet-1/1]` on one link and `[d3l:e1-2, h4:e1-1]` on another — both
  came up. `[LAB]`
- Regex: `ethernet-(?P<linecard>\d+)/(?P<port>\d+)(?:/(?P<channel>\d+))?`;
  help string `ethernet-L/P, ethernet-L/P/C or eL-P, eL-P-C (where L, P, C >= 1)`.
- **Breakout**: `ethernet-1/3/1` ↔ `e1-3-1`. Containerlab auto-emits
  `breakout-mode num-breakout-ports 4 breakout-port-speed 25G` and refuses `mtu` on a breakout port
  (`must 'not(../breakout-mode)'`). `[VERIFIED: srl_default_config.go.tpl; srl_nokia-interfaces.yang:855-857]`

**Recommendation**: use the **device-native `ethernet-1/N`** form in the topology file. It makes
the containerlab link list, the site inventory (PC-A-07), the gNMI paths and the Grafana labels the
*same string*, which is the whole point of PC-A-09's join contract.

### 3.2 The special interfaces

`[VERIFIED: …/interfaces/srl_nokia-interfaces.yang:1527-1560]` — the complete legal name list:

```
irb<N>, N=0..255          lo<N>, N=0..255           mgmt0        mgmt0-standby
mgmtA  mgmtB              system0                   sync0-a / sync0-b
ethernet-<slot>/<port>[/<connector>]  lag<N>, N=1..1000  lif-e1-<N>  vhn-<name>  enp<b>s<d>f<f>
```

| Name | Role |
|---|---|
| **`mgmt0`** | The only management port. Lives in the separate `srbase-mgmt` netns. DHCP client by default; belongs to `network-instance mgmt` (type `ip-vrf`). Port MTU default **1514**, max **9216** |
| **`system0`** | The system loopback. **`system0.0`'s IPv4 address is the VXLAN VTEP source and the default BGP next-hop** — the vxlan-interface `egress source-ip` enum is literally `use-system-ipv4-address`, and the bgp-evpn `next-hop` default is `use-system-ipv4-address`. Verified on the wire: outer VXLAN src/dst were `10.0.0.1`/`10.0.0.2`, the two `system0.0` addresses `[LAB]`. `ip-mtu` and `mpls-mtu` are **not configurable** on `system`/`lo` interfaces (`must "not (starts-with(…, 'system') or starts-with(…, 'lo'))"`) |
| **`lo0`–`lo255`** | Ordinary additional loopbacks; **not** the VTEP source. Use `lo0` for a router-id/service loopback if you need one distinct from `system0` |
| **`irb0`–`irb255`** | The L2↔L3 stitch. `irb<N>.<index>` is a routed subinterface placed in an `ip-vrf` and referenced by a `mac-vrf` — this is the SR Linux successor to SONiC's "derived routed instance VLAN" (PC-15). **PC-15's 4001–4094 band and the VNI→routed-VLAN derivation simply do not exist here**; `irb` subinterface indices are free. Port `mtu` is not configurable on irb; use `subinterface ip-mtu` |
| **`lag1`–`lag1000`** | LAG. Max per platform: D1 32, D2/D3 128 |

### 3.3 Subinterface model and `vlan-tagging`

`[VERIFIED: /root/learn-srlinux/docs/tutorials/l2evpn/evpn.md:139-165,455-490]`

```
interface ethernet-1/1 {
    vlan-tagging true                # enable 802.1Q on the port
    subinterface 0 {
        type bridged                 # bridged | routed | local-mirror-dest
        admin-state enable
        vlan { encap { untagged { } } }      # or: single-tagged { vlan-id 100 }
    }
}
```

- `type bridged` → attachable only to a `mac-vrf`; enables MAC learning. `type routed` → attachable
  to `default` or an `ip-vrf`.
- `vlan-tagging false` + `subinterface 0` + no `vlan` container is the simplest untagged access port
  (what I used `[LAB]`).
- The subinterface **index is not the VLAN ID**. The VLAN ID lives in `vlan/encap/single-tagged/vlan-id`.
  That decouples the two, and is another reason PC-15's derivation vanishes.
- `network-instance` types are **`default`, `ip-vrf`, `mac-vrf`, `vpws`, `host`**
  `[VERIFIED: …/network-instance/srl_nokia-network-instance.yang:142-178]`.
  **This is the direct hit on spec §Open decisions 5**: SR Linux's own model names its bridged and
  routed instances `mac-vrf` and `ip-vrf`, identically to FR-024's construct vocabulary. The
  vocabulary stops being a translation layer and becomes the device's literal terminology.
  Network-instance names use `srl_nokia-comm:restricted-name` — length `1..247`, pattern
  ``[A-Za-z0-9!@#$%^&()|+=`~.,_:;?-][A-Za-z0-9 !@#$%^&()|+=`~.,_:;?-]*`` (note: no `/`, unlike
  `name`) `[VERIFIED: srl_nokia-common.yang:1319-1326]`.

### 3.4 VXLAN object model

```
tunnel-interface vxlan1 {                      # name pattern: vxlan<N>, N=0..255, length 6..8
    vxlan-interface 1 {                        # index 0..99999999, max-elements 16384
        type bridged                           # bridged → mac-vrf ; routed → ip-vrf
        ingress { vni 100 }                    # 1..16777215
        egress  { source-ip use-system-ipv4-address }   # the ONLY legal value
    }
}
network-instance vlan100 {
    type mac-vrf
    interface ethernet-1/1.0 { }
    vxlan-interface vxlan1.1 { }
    protocols {
        bgp-evpn  { bgp-instance 1 { vxlan-interface vxlan1.1  evi 100 } }
        bgp-vpn   { bgp-instance 1 { route-target { export-rt target:100:100  import-rt target:100:100 } } }
    }
}
```
`[VERIFIED: …/tunnel/srl_nokia-tunnel-interfaces.yang:60-200; /root/learn-srlinux/docs/tutorials/l2evpn/evpn.md:167-230]`
and deployed working `[LAB]`.

### 3.5 Proposed interface map for the reference topology

Node names unchanged from the composite (`spine01`, `spine02`, `leaf01`, `leaf02`, `client01`,
`client02`, plus two more endpoints). With SRv6 dropped (§2.4), `srv6-client01/02` should be renamed
`client03`/`client04` and repurposed as a second EVPN service's endpoints — FR-003's IPv6-underlay
clause has no substrate and should be deleted, not translated.

```yaml
name: agentic-netops-fabric
mgmt:
  network: agentic-netops-mgmt        # pre-created & labelled by provision.sh (reused, see §4.5)
  ipv4-subnet: 172.31.0.0/16          # ← see §4.6: collides on this host today
topology:
  kinds:
    nokia_srlinux:
      image: ghcr.io/nokia/srlinux@sha256:6ab1250cbff4b536e0996e57d2d9c2a7bf3154028c21e4c978e13254add3c402
  nodes:
    spine01: { kind: nokia_srlinux, type: ixr-d3l, mgmt-ipv4: 172.31.0.11, labels: { role: spine } }
    spine02: { kind: nokia_srlinux, type: ixr-d3l, mgmt-ipv4: 172.31.0.12, labels: { role: spine } }
    leaf01:  { kind: nokia_srlinux, type: ixr-d2l, mgmt-ipv4: 172.31.0.21, labels: { role: leaf } }
    leaf02:  { kind: nokia_srlinux, type: ixr-d2l, mgmt-ipv4: 172.31.0.22, labels: { role: leaf } }
    client01: { kind: linux, mgmt-ipv4: 172.31.0.101, labels: { attach: leaf01 } }
    client02: { kind: linux, mgmt-ipv4: 172.31.0.102, labels: { attach: leaf02 } }
    client03: { kind: linux, mgmt-ipv4: 172.31.0.111, labels: { attach: leaf01 } }
    client04: { kind: linux, mgmt-ipv4: 172.31.0.112, labels: { attach: leaf02 } }
  links:
    # fabric — leaf uplinks are the d2l 100G block; spine ports are the d3l 100G block
    - endpoints: [spine01:ethernet-1/1, leaf01:ethernet-1/49]
    - endpoints: [spine01:ethernet-1/2, leaf02:ethernet-1/49]
    - endpoints: [spine02:ethernet-1/1, leaf01:ethernet-1/50]
    - endpoints: [spine02:ethernet-1/2, leaf02:ethernet-1/50]
    # endpoints — leaf access block
    - endpoints: [leaf01:ethernet-1/1, client01:eth1]
    - endpoints: [leaf02:ethernet-1/1, client02:eth1]
    - endpoints: [leaf01:ethernet-1/2, client03:eth1]
    - endpoints: [leaf02:ethernet-1/2, client04:eth1]
```

Full name/port map for the site inventory (PC-A-07):

| Device | Port | Peer | Role |
|---|---|---|---|
| spine01 | `ethernet-1/1`, `ethernet-1/2` | leaf01, leaf02 | fabric, 100G |
| spine02 | `ethernet-1/1`, `ethernet-1/2` | leaf01, leaf02 | fabric, 100G |
| leaf01 | `ethernet-1/49`, `ethernet-1/50` | spine01, spine02 | fabric uplinks, 100G |
| leaf01 | `ethernet-1/1`, `ethernet-1/2` | client01, client03 | access, 25G |
| leaf02 | `ethernet-1/49`, `ethernet-1/50` | spine01, spine02 | fabric uplinks, 100G |
| leaf02 | `ethernet-1/1`, `ethernet-1/2` | client02, client04 | access, 25G |
| all | `system0.0` | — | VTEP source + BGP router-id |
| all | `mgmt0` | docker `agentic-netops-mgmt` | gNMI/JSON-RPC/SSH |
| leaf01/02 | `irb<N>` | — | created per routed service |

**Do NOT set `mgmt.mtu`** — see §8.5.

---

## 4. Management plane

### 4.1 Credentials

**`admin` / `NokiaSrl1!`** (`admin:admin` prior to 22.11.1).
`[VERIFIED: srl.go:71 `defaultCredentials = clabnodes.NewCredentials("admin", "NokiaSrl1!")`;
containerlab/docs/manual/kinds/srl.md:120]` Confirmed live `[LAB]`.
In bash the `!` **must** be single-quoted or history expansion eats it.

Containerlab also injects `~/.ssh` public keys for `admin` and `linuxadmin`
(`set / system aaa authentication {admin,linuxadmin}-user ssh-key [ … ]`, max 32 keys, sorted
deterministically) `[VERIFIED: srl_default_config.go.tpl; version.go:152-184]`.

### 4.2 Ports — all verified live `[LAB]`

| Service | Port | Transport | Notes |
|---|---|---|---|
| **gNMI / gNOI / gNSI / gRIBI / P4RT** | **57400** | TLS, profile `clab-profile` | server instance `mgmt`; **57400 is the YANG default** (`leaf port { type srl-comm:port-number; default "57400"; }` `[VERIFIED: …/grpc/srl_nokia-grpc.yang:415-421]`) |
| same services, **no TLS** | **57401** | plaintext | server instance `insecure-mgmt`, added by containerlab; CPM ACL entries 358 (v4) / 368 (v6) allow it |
| JSON-RPC | **80** (HTTP) / **443** (HTTPS) | `/jsonrpc` | HTTPS uses `clab-profile` |
| NETCONF | **830** | SSH | 24.7.1+; ssh-server instance `mgmt-netconf`, `disable-shell true` |
| SSH | **22** | — | |
| SNMPv2 | **161** | community `public` | |
| EDA discovery / mgmt / insecure-mgmt | **50052 / 57410 / 57411** | | added on 24.10+; **consume ports even if EDA is unused** |

Verified by probe: `gnmic … -a <ip>:57400 --skip-verify` OK; `-a <ip>:57401 --insecure` OK;
`curl http://admin:…@<ip>/jsonrpc` OK; `curl -k https://…` OK; TCP 830 and 22 open. `[LAB]`

### 4.3 What containerlab writes into the config

Exact rendered blocks `[VERIFIED: containerlab/nodes/srl/version_configs/{grpc,tls,netconf,oc,snmpv2,acl}.cfg
and srl_default_config.go.tpl]`, confirmed on a live 26.7.2 node `[LAB]`:

```
set / system tls profile clab-profile                        # ← 26.3+; "tls server-profile" before 26.3
set / system tls profile clab-profile key "<encrypted>"
set / system tls profile clab-profile certificate "<PEM>"
set / system tls profile clab-profile authenticate-client false

set / system grpc-server mgmt services [ gnmi gnoi gnsi gribi p4rt ]
set / system grpc-server mgmt tls-profile clab-profile
set / system grpc-server mgmt rate-limit 65000
set / system grpc-server mgmt network-instance mgmt
set / system grpc-server mgmt trace-options [ request response common ]
set / system grpc-server mgmt unix-socket admin-state enable
set / system grpc-server mgmt admin-state enable
delete / system grpc-server mgmt default-tls-profile

set / system grpc-server insecure-mgmt services [ gnmi gnoi gnsi gribi p4rt ]
set / system grpc-server insecure-mgmt port 57401
… (+ CPM ACL entries 358/368 for tcp/57401)

set / system json-rpc-server admin-state enable network-instance mgmt http  admin-state enable
set / system json-rpc-server admin-state enable network-instance mgmt https admin-state enable tls-profile clab-profile

set / system netconf-server mgmt admin-state enable ssh-server mgmt-netconf   # 24.7+
set / system management openconfig admin-state enable                          # 24.10+, if the image has the feature
set / system ndk-server admin-state enable                                     # 25.3+
set / system lldp admin-state enable
set / system aaa authentication idle-timeout 7200
```

**Version-gated** `[VERIFIED: containerlab/nodes/srl/version.go:148-240]`:
`≥23.10` ssh keys via CLI · `≥24.3` CPM ACL for HTTP/Telnet + the `grpc-server` block (below that:
the old `system gnmi-server`) · `≥24.7` NETCONF · `≥24.10` EDA + OpenConfig ·
`≥25.3` NDK · `≥26.3` `tls profile` instead of `tls server-profile`.

**This means the pin and the containerlab version are coupled**: a pin below 24.3 silently gets a
different gRPC config shape, and containerlab below 26.x would emit the wrong TLS path for a 26.x
image. 0.79.0 + 25.7.1 is inside a well-tested window; 0.79.0 + 26.7.2 was verified live `[LAB]`.

### 4.4 TLS / certificates

Containerlab generates a per-lab CA and per-node cert
`[VERIFIED: containerlab/docs/manual/kinds/srl.md:344-380]`:

```
<lab-dir>/.tls/ca/ca.pem          <lab-dir>/.tls/ca/ca.key
<lab-dir>/.tls/<node>/<node>.pem  <lab-dir>/.tls/<node>/<node>.key
```

- Files **persist across redeploys** of the same lab.
- Subjects/SANs (for node `srl`, lab `srl`): `DNS:srl, DNS:clab-srl-srl, DNS:srl.srl.io,
  IP:172.20.20.3, IP:3fff:172:20:20::3`. Confirmed on a live cert: CN `d3l.typeprobe.io`,
  SAN `DNS:d3l, DNS:clab-typeprobe-d3l, DNS:d3l.typeprobe.io, IP:172.23.77.11`. `[LAB]`
- Node cert issuance is **forced** for this kind (`n.Cfg.Certificate.Issue = new(true)`)
  `[VERIFIED: srl.go:239-241]`.
- Extra SANs via the node-level `subject-alternative-names` directive.
- `authenticate-client false` — **the server does not require a client cert**, so the
  device-configuration layer only needs the CA to verify the server (or `--skip-verify`).

**For FR-075's NetworkPolicy denial dial**: the in-cluster CA bundle should be
`<lab-dir>/.tls/ca/ca.pem`, and the gNMI port in the denial probe changes from SONiC's to **57400**
(and 57401 must be denied too — it is plaintext and would otherwise be an unauthenticated bypass of
the whole safety boundary). **This is a real security-relevant change to PC-A-06.**

### 4.5 Management network instance, and the Kind↔SRL path

SR Linux's management stack lives in its own netns `srbase-mgmt`; `mgmt0` belongs to
`network-instance mgmt`, type `ip-vrf`, with `protocols linux import-routes/export-routes true`.
Verified live `[LAB]`:

```
set / network-instance mgmt type ip-vrf
set / network-instance mgmt admin-state enable
set / network-instance mgmt interface mgmt0.0
set / interface mgmt0 subinterface 0 ipv4 dhcp-client
set / interface mgmt0 subinterface 0 ipv6 dhcp-client
```

Because of the separate netns, *"the DNS resolver provided by Docker in the root network namespace
is not available to the SR Linux management stack"* — containerlab compensates by extracting the
host's resolvers into `system dns server-list`.
`[VERIFIED: containerlab/docs/manual/kinds/srl.md:471-500]`

**`mgmt:` settings — confirmed working exactly as the existing design uses them** `[LAB]`:

| Setting | Behaviour |
|---|---|
| `network: <name>` | If the Docker network already exists, containerlab **reuses** it. Source comment: `// CreateNet creates a docker network or reusing if it exists.` `[VERIFIED: containerlab/runtime/docker/docker.go:190-232]`. **Proved**: I pre-created `netreuse-mgmt` with `docker network create --subnet … --label agentic-netops.owner=…`, deployed a lab naming it, and containerlab printed **no** "Creating docker network" line, attached the node, and the label survived `[LAB]` |
| `ipv4-subnet: 172.31.0.0/16` | Must match the pre-created subnet, and must be explicit for per-node `mgmt-ipv4` to work |
| `mgmt-ipv4: 172.31.0.21` | **Works.** Verified: node came up on exactly `172.23.79.21` on the pre-created network `[LAB]` |
| `mtu:` | **Do not use** — see §8.5 |

The Kind side is unchanged from the SONiC design: `docker network connect "${MGMT_NET}" "${node}"`
for each Kind node `[VERIFIED: /root/agentic-netops/scripts/lib/kind.sh:140]`. Nothing about that
mechanism is NOS-specific. Only the target port changes (`8080` → `57400`) — note
`/root/agentic-netops/scripts/lib/persistence.sh:23` currently hard-codes
`TARGETS="172.31.0.21:8080,172.31.0.22:8080"`.

### 4.6 ⚠️ `172.31.0.0/16` is occupied on this host today

`ip -4 route` shows `172.31.0.0/16 dev br-0540d6e2ffa8` — the Docker network
`sovereign_lane_a_noegress`. `[LAB]` The provisioning preflight
(`/root/agentic-netops/scripts/lib/preflight.sh:97`) checks overlap against pod/service CIDRs but
apparently not against other Docker networks. **Either pick a different /16 (e.g. `172.26.0.0/16`)
or extend the preflight to scan `docker network ls` + `ip route`.** This is a deployment blocker on
*this* host, independent of the retarget.

---

## 5. Host requirements — and the death of PC-03

### 5.1 No KVM, no nested virtualisation. Confirmed.

The SR Linux kind sets **no virtualisation requirement at all**
`[VERIFIED: containerlab/nodes/srl/srl.go:200-206]`:

```go
n.HostRequirements.SSSE3 = true
n.HostRequirements.MinVCPU = 2
n.HostRequirements.MinVCPUFailAction = clabtypes.FailBehaviourError
n.HostRequirements.MinAvailMemoryGb = 2
n.HostRequirements.MinAvailMemoryGbFailAction = clabtypes.FailBehaviourLog
```

Compare `nodes/vr-*` kinds, which set `VirtRequired`. SR Linux is a **native container** — the
startup command is `sudo -E bash -c 'touch /.dockerenv && /opt/srlinux/bin/sr_linux'`
`[VERIFIED: srl.go:245-249]`. Four nodes booted on this host in ~3 minutes with no `/dev/kvm`
involvement `[LAB]`.

### 5.2 Hard requirements

| Requirement | Value | Source |
|---|---|---|
| **SSSE3** | Required — *"SR Linux XDP — the emulated datapath based on DPDK — requires SSSE3 instructions… containerlab will abort the lab deployment"* | `[VERIFIED: containerlab/docs/manual/kinds/srl.md:509-520]`; present on this host `[LAB]` |
| **Kernel** | `requiredKernelVersion = 4.10.0`, checked and enforced | `[VERIFIED: srl.go:145-151, 502]`; host runs 7.0.14 `[LAB]` |
| **vCPU** | ≥ 2 available, **hard error** if not | `[VERIFIED: srl.go:202-203]` |
| **RAM** | ≥ 2 GB available, **warning only** | `[VERIFIED: srl.go:204-205]` |
| **Sysctls** (set automatically) | `net.ipv4.ip_forward=0`, `net.ipv6.conf.all.disable_ipv6=0`, `net.ipv6.conf.{all,default}.accept_dad=0`, `net.ipv6.conf.{all,default}.autoconf=0` | `[VERIFIED: srl.go:64-70]` |
| **tmpfs** | `/run/netns` mounted `rw,nosuid,nodev,noexec` so network-instance netns don't survive restarts | `[VERIFIED: srl.go:276-282]` |
| **Container user** | `0:0` (root) | `[VERIFIED: srl.go:251-254]` |

Nokia's own documented minimum is 4 GB / 2 vCPU per container; learn.srlinux.dev quotes 2 vCPU /
2 GB. `[VERIFIED via parallel probe: documentation.nokia.com install-containers]`

### 5.3 Measured resource footprint `[LAB]`

Four idle SR Linux 26.7.2 nodes, cgroup `memory.current`:

| type | RSS idle |
|---|---|
| `ixr-d2l` | **1797 MiB** |
| `ixr-d3l` | **1795 MiB** |
| `ixr-d5` | **1832 MiB** |
| `ixr-h4` | **1385 MiB** |

`memory.stat` on d2l: `anon 1793560576` — i.e. it really is ~1.75 GiB of anonymous memory, not page
cache. 96 processes per node. Boot to gNMI-ready: **~3 minutes** for a 4-node lab (containerlab's
`readyTimeout` is 5 minutes `[VERIFIED: srl.go:35]`).

⚠️ **`docker stats` reports `0B / 0B` for SR Linux containers** on this host `[LAB]` — corroborated
upstream (*"the stats for the lab container have been all zeroes for a long time"*,
nokia/srlinux-container-image issue #2 `[VERIFIED via parallel probe]`). **Any resource check in
`provision.sh` must read cgroups directly, not the Docker stats API.**

### 5.4 Max nodes on this host, and the NFR-004 rewrite

Budget on a 22-core / 93 GB host, assuming ~1.8 GiB/node and ≥2 vCPU each:

- **Memory-bound**: 93 GB total, but ~68 GB was already in use by other workloads at the start of
  this session. With a clean host, ~45 SR Linux nodes fit in 80 GB. **On this host as it stands
  today, ~10–12 nodes.** The 8-node reference topology (4 SRL + 4 Linux ≈ 7.2 GB + ~0.4 GB) fits
  comfortably — I ran 4 SRL + 2 Linux plus another agent's 5-node lab concurrently `[LAB]`.
- **CPU-bound**: nodes are idle-cheap; the 22 cores are not the limit at this scale.
- **Practical recommendation for the spec**: state **8 GB RAM and 4 vCPU headroom for the four SR
  Linux nodes**, plus whatever the Kind cluster needs, and require the preflight to check
  *available* rather than *total* memory.

**PC-03 collapses.** There is no "fast profile vs conformance VM profile" split, because:

- There is only **one** artifact — the container image. There is no VM variant to fall back to.
  (Nokia's separate VM-based **vSRL** product exists, but its YANG gates — `vsrl`, `platform-vsrl`,
  BFD ≥ 1 s, ECMP ≤ 16, no ACL policer stats — are **not set** on any containerlab 7220 node
  `[LAB]`, so vSRL is a different animal, not a "conformance profile" of this one.)
- The container **passes** the EVPN/VXLAN qualification that PC-03's fallback existed for — proved
  end to end in §9.
- The KVM/nested-virt clause has nothing to attach to.

> **Proposed NFR-004 replacement**
>
> **NFR-004**: The reference lab MUST be reproducible on a documented Linux host. The host
> qualification MUST state: a CPU exposing the **SSSE3** instruction set (the emulated datapath
> requires it; hypervisor guests MUST use a `host`-passthrough CPU model), kernel **≥ 4.10**,
> at least **2 vCPU and 2 GB of available RAM per network node** plus the cluster's own budget,
> and Docker with a management network whose address space is verified free of collision with any
> existing Docker network or host route. The lab MUST NOT require KVM, nested virtualization or
> any hardware acceleration. There is exactly one device profile; any capability the single
> profile fails is reported as a gate failure and never routed to a second profile.

The `--profile sonic-vs` / `--profile sonic-vm` flag pair in `provision.sh` (PC-A-13) should be
**deleted**, not renamed. Quickstart §1's fallback block ("If the fast profile fails its unmodified
capability gate: `off.sh` then `provision.sh --profile sonic-vm`") should be deleted with it.

---

## 6. Configuration persistence, startup and commit semantics

### 6.1 `startup-config`

`[VERIFIED: containerlab/docs/manual/kinds/srl.md:210-320]`

Two formats, auto-detected by whether the first non-whitespace byte is `{`:

- **JSON** — a complete `/etc/opt/srlinux/config.json`. Copied verbatim into
  `clab-<lab>/<node>/config/config.json`.
- **CLI** — a *partial* config, either indented (`info`) or flat (`info flat` / `set / …`).
  Copied to `/tmp/clab-overlay-config` and applied with
  `su -s /bin/bash admin -c '/opt/srlinux/bin/sr_cli -ed < /tmp/clab-overlay-config'`, then
  `sr_cli -ed "commit save"`. *"no entering into the candidate config, nor explicit commit is
  required to be part of the CLI configuration snippets."*

⚠️ **If `clab-<lab>/<node>/config/config.json` already exists, containerlab skips config generation
entirely.** `[VERIFIED: parallel probe of srl.go:352-371]` A "clean redeploy" therefore requires
`containerlab destroy --cleanup` or removing the lab directory — relevant to SC-003's "leaves no
platform-owned resources".

⚠️ **Gotcha I hit `[LAB]`**: applying a flat CLI file with `sr_cli -ed < file` does **not**
auto-commit; you need a subsequent `sr_cli -ed 'commit now'`. Containerlab does this for you;
a hand-rolled bootstrap must too.

Containerlab also creates a config checkpoint named **`clab-initial`** after deploy, for quick
revert.

### 6.2 `save startup`

- CLI: `tools system configuration save` (writes `/etc/opt/srlinux/config.json`), or `commit save`,
  or `save startup`.
- `containerlab save -t <topo>` runs
  `/opt/srlinux/bin/sr_cli -d "tools system configuration save"` on every SRL node
  `[VERIFIED: srl.go:137]`.
- The whole `/etc/opt/srlinux/` directory is bind-mounted `rw` from `<labdir>/<node>/config`
  `[VERIFIED: srl.go:268-269]` — so the startup config is host-visible and survives container
  restarts.

### 6.3 What a gNMI Set persists — **running only**

A gNMI Set writes the running datastore. A container restart loses it unless a save happens.
`[VERIFIED by parallel probe: set a network-instance, `grep config.json` → 0 hits,
`docker restart`, instance gone]`

Two ways to make gNMI writes durable, both settable **over gNMI itself**:

| Path | Type / default | First released |
|---|---|---|
| `/system/configuration/auto-save` | boolean, default `false` | 24.7.1 |
| `/system/grpc-server[name=<srv>]/gnmi/commit-save` | boolean, default `false` | 21.3.1 |
`[VERIFIED: …/system/srl_nokia-configuration.yang:265-278; …/grpc/srl_nokia-gnmi.yang]`

⚠️ **There is no gNMI path that triggers a one-off save.** The `srl_nokia-tools-configuration`
tree (`save`, `rescue-save`, `checkpoint/{clear,load,revert}`, `confirmed-accept`,
`confirmed-reject`, `candidate/{lock,unlock}`) is reachable from CLI and JSON-RPC
(`"datastore": "tools"`) but **not** from gNMI — gNMI has no datastore selector and no `tools`
origin. Attempting `tools:/system/configuration/save` returns
`InvalidArgument desc = Path not valid - unknown element 'save'`.
`[VERIFIED by parallel probe]` sdcio's own Schema CR reflects this: `excludes: [".*tools.*"]`.

**Recommendation**: set `/system/configuration/auto-save true` once at onboarding. Then FR-042's
apply-and-read-back is durable without a second interaction class.

### 6.4 Candidate / commit over gNMI

- **Each gNMI SetRequest is one implicit private candidate + commit.** `/system/configuration/commit`
  (config false) shows one entry per Set, `type: private`, name `grpcrpc-<n>` on 25.10.3
  (Nokia's docs say `gnmirpc-<n>` — stale). `[VERIFIED by parallel probe]`
- **Atomic.** A two-update Set whose second update was out of range failed the whole request and
  left the first leaf unchanged. `[VERIFIED by parallel probe]` Nokia: *"Either all modifications
  are applied or changes are rolled back."*
- **No multi-message transaction.** Batch everything atomic into one SetRequest; `delete`,
  `replace`, `update` are applied in that order.
- **No server-side dry-run over gNMI.** `gnmic --dry-run` is client-side only. Server-side
  `Validate` exists only on JSON-RPC (`commit validate`) and CLI.
- **`commit confirmed` DOES work over gNMI** — SR Linux implements the OpenConfig Commit Confirmed
  extension v0.1.0. Full lifecycle verified `[VERIFIED by parallel probe]`:
  ```bash
  gnmic … set --commit-request --commit-id apply-42 --rollback-duration 120s --update-path … --update-value …
  gnmic … set --commit-confirm --commit-id apply-42     # or --commit-cancel
  ```
  Auto-revert observed after a 10 s `--rollback-duration` with no confirm.
  Server-side default: `/system/grpc-server[name=<srv>]/gnmi/commit-confirmed-timeout`, uint32
  `0..86400` s, default `0` (= client-driven only).
  **This is a strictly better safety net than anything SONiC offered, and CR-004's "declarative
  transaction" gains a real rollback primitive.**

### 6.5 Encoding / origin caveats that bite an apply-and-read-back controller

- **Encodings**: Capabilities advertises `JSON_IETF`, `PROTO`, `ASCII` + Nokia-private numeric
  encodings 42–53. **`JSON` (enum 0) is NOT advertised and NOT accepted for Get** —
  `Unimplemented … (received encoding: 0)`. **gnmic's default is `json`, so always pass
  `-e json_ietf`.** `[LAB + VERIFIED by parallel probe]`
- **Origins**: documented values are `openconfig`, `native`/`srlinux_native`, `cli`/`srlinux_cli`.
  **`srl_nokia` is NOT a documented origin** — it works only because *anything* not
  `openconfig`/`cli` resolves to native, silently, including typos. **Use `native:`.**
  `[VERIFIED by parallel probe]`
- **OpenConfig origin** requires `/system/management/openconfig/admin-state = enable` (which has a
  `must` dependency on the LLDP presence container). Containerlab enables both on ≥24.10 images
  whose `system features` contains `openconfig`. OC **is writable** and mirrors into the native
  tree. **But OC coverage for a fabric is unusable**: `mappings/openconfig/oc-srl-network-instance.json`
  is **73 % `"supported": false` (833 of 1137 entries)**, and `oc-srl-unsupported.json` excludes
  `/network-instances/network-instance/evpn`, `…/vlans`, `…/mpls`, `…/ospfv2`, `…/ospfv3`, `…/pim`,
  `…/igmp`, `…/pcep`, `…/segment-routing` and `/keychains` outright.
  `[VERIFIED: scratchpad/yang/srlinux-yang-models/mappings/openconfig/]`
  **→ PC-14's OpenConfig-vs-native path register survives, and its content is: native for
  everything in the fabric render path.** FR-017 and D-09 keep their teeth.
- **Defaults are omitted from `-t CONFIG` reads** unless
  `/system/grpc-server[name=<srv>]/gnmi/include-defaults-in-config-only-responses` is `true`
  (default `false`). A naive desired-vs-actual diff will report spurious drift for every leaf set
  to its default. `[VERIFIED by parallel probe]`
- **`replace` at container level deletes siblings** and can fail on *leafref'd* state you never
  touched (a `replace` on `/interface[name=mgmt0]` removed `subinterface 0` and the whole
  transaction rolled back because `network-instance mgmt` referenced `mgmt0.0`). **Prefer `update`
  plus explicit `delete`.** `[VERIFIED by parallel probe]`
- **Deleting a nonexistent instance succeeds** (idempotent); deleting an unknown *element* is
  `InvalidArgument`. Good for reconcile loops, useless as an existence probe.
- **Rate limit**: `/system/grpc-server[name]/rate-limit` **defaults to 60 RPC/min** on a real box
  and returns `ResourceExhausted` past it. Containerlab sets **65000**, so a clab lab never trips
  it — but this is a production-vs-lab divergence worth a note. `session-limit` defaults to 20 and
  counts each active Subscribe. `[VERIFIED: …/grpc/srl_nokia-grpc.yang:474-566 + parallel probe]`
- **`max-paths-per-subscription-request` defaults to 36**
  `[VERIFIED: srl_nokia-configuration.yang:279-286]` — a wide FR-089 subscription will be rejected
  past 36 paths.

---

## 7. The FR-004 capability gate, rewritten for SR Linux (replaces PC-02 / PC-A-03)

Prerequisites: `gnmic` ≥ 0.47.0. Variables:

```bash
SRL=172.31.0.21                       # leaf01
U=admin; P='NokiaSrl1!'               # single quotes are mandatory
TLS="-a ${SRL}:57400 -u $U -p $P --skip-verify -e json_ietf"
# or, with the containerlab CA:  --tls-ca <labdir>/.tls/ca/ca.pem
```

### G1 — gNMI Capabilities: models and encodings

```bash
gnmic $TLS capabilities
```

**Assert**:
- `gNMI version:` is present (observed **`0.10.0`** on 25.10.3 — **do not gate on `0.7.0`**,
  which is what Nokia's docs still print). `[VERIFIED by parallel probe]`
- `supported encodings` contains **`JSON_IETF`**. (Do **not** require `JSON`.) `[LAB]`
- `supported models` (**367 entries** on 25.10.3 `[LAB]`) contains **all** of these
  `name, organization, version` triples — every one observed live `[LAB]`:

| Model `name` | org | revision on 25.10.3 |
|---|---|---|
| `urn:nokia.com:srlinux:interfaces:interfaces:srl_nokia-interfaces` | Nokia | (image train) |
| `urn:nokia.com:srlinux:net-inst:network-instance:srl_nokia-network-instance` | Nokia | |
| `urn:nokia.com:srlinux:bgp:bgp:srl_nokia-bgp` | Nokia | `2025-10-31` |
| `urn:nokia.com:srlinux:net-inst:bgp-evpn:srl_nokia-bgp-evpn` | Nokia | `2025-10-31` |
| `urn:nokia.com:srlinux:bgp:bgp-vpn:srl_nokia-bgp-vpn` | Nokia | `2025-10-31` |
| `urn:nokia.com:srlinux:vxlan:tunnel-interfaces:srl_nokia-tunnel-interfaces` | Nokia | `2025-10-31` |
| `urn:nokia.com:srlinux:acl:acl:srl_nokia-acl` | Nokia | `2025-10-31` |
| `urn:nokia.com:srlinux:net-inst:bridge-table:srl_nokia-bridge-table` | Nokia | `2024-07-31` |
| `urn:nokia.com:srlinux:l2-mac:bridge-table-mac-table:srl_nokia-bridge-table-mac-table` | Nokia | `2025-10-31` |
| `urn:nokia.com:srlinux:net-inst:system-network-instance:srl_nokia-system-network-instance` | Nokia | `2024-07-31` |
| `urn:nokia.com:srlinux:chassis:mtu:srl_nokia-mtu` | Nokia | `2025-07-31` |
| `urn:nokia.com:srlinux:general:configuration:srl_nokia-configuration` | Nokia | `2025-03-31` |
| `urn:ietf:params:xml:ns:yang:ietf-yang-library:ietf-yang-library` | IETF NETCONF … WG | `2019-01-04` |

⚠️ **Do not string-match on the old `urn:srl_nokia/bgp:srl_nokia-bgp` form** — Nokia changed the
name string; `nornir-srl` carries both constants for exactly this reason
`[VERIFIED: /root/nornir-srl/nornir_srl/connections/routing.py:528-529]`. Match on the module
suffix (`srl_nokia-bgp-evpn`) and assert the `version` (revision date) equals the pinned train's.

### G2 — Version and platform identity

```bash
gnmic $TLS get --path /system/information/version --path /platform/chassis/type
```
**Assert**: `version` starts with the pinned train (e.g. `v25.7.1-`); `chassis/type` is
`"7220 IXR-D2L"` on leaves and `"7220 IXR-D3L"` on spines. Live example `[LAB]`:
`"version": "v26.7.2-519-g94fbd638fa8"`, `"type": "7220 IXR-D2L"`.

### G3 — Platform feature set (replaces PC-04's SRv6 block)

```bash
gnmic $TLS get --path /system/features
```
**Assert present**: `vxlan`, `evpn`, `evpn-vxlan-mac-vrf`, `evpn-vxlan-ifl`, `bridged`,
`acl-filter-mac`, `acl-subinterface-entry-statistics`, `acl-if-output-shared-tcam-entries`,
`egress-mac-filter-restriction`, `vxlan-stats`, `openconfig`, `config-sub-if-l2-mtu`.
**Assert absent (and record the absence rather than failing)**: `srv6`, `srv6-dt2`, `mpls`,
`vxlan-v6`.
All twelve "present" assertions verified on live `ixr-d2l`/`ixr-d3l` 26.7.2 `[LAB]`.

### G4 — Writable, persistent configuration (Set + read-back + durability)

```bash
# Set
gnmic $TLS set --update-path "native:/interface[name=ethernet-1/1]/description" \
               --update-value "capability-gate"
# Read back from the config datastore
gnmic $TLS get -t CONFIG --path "/interface[name=ethernet-1/1]/description"
# Durability switch
gnmic $TLS set --update-path /system/configuration/auto-save --update-value true
gnmic $TLS get -t CONFIG --path /system/configuration/auto-save
# Clean up
gnmic $TLS set --delete "native:/interface[name=ethernet-1/1]/description"
```
**Assert**: the Set returns `operation: UPDATE`; the Get returns the exact value; `auto-save` reads
back `true`. **Never trust the SetResponse alone** — a bare JSON array at a list path returns
success and silently applies nothing `[VERIFIED by parallel probe]`.

### G5 — Commit-confirmed (the rollback primitive CR-004 needs)

```bash
gnmic $TLS set --commit-request --commit-id gate --rollback-duration 30s \
               --update-path "native:/interface[name=ethernet-1/1]/description" --update-value "cc"
gnmic $TLS get -t CONFIG --path "/system/configuration/commit"      # expect status "unconfirmed"
gnmic $TLS set --commit-confirm --commit-id gate
gnmic $TLS get -t CONFIG --path "/system/configuration/commit"      # expect status "complete"
```

### G6 — MTU envelope (new; see §8)

```bash
gnmic $TLS get --path /system/mtu
gnmic $TLS set --update-path "/interface[name=ethernet-1/49]/mtu" --update-value 9412
gnmic $TLS set --update-path "/interface[name=ethernet-1/49]/subinterface[index=0]/ip-mtu" \
               --update-value 9398
```
**Assert**: `/system/mtu` reads `{"default-ip-mtu":1500,"default-l2-mtu":9232,"default-port-mtu":9232,"min-path-mtu":552}`
`[LAB]`; both Sets succeed; `mtu 9413` is rejected with
`[InvalidArgument] mtu 9500 out of range [1500-9412]` and `ip-mtu 9399` with
`[InvalidArgument] 9399 out of range [1280-9398]` — **both exact strings verified live** `[LAB]`.

### G7 — Subscribe

```bash
gnmic $TLS subscribe --mode once --path "/interface[name=mgmt0]/statistics"
gnmic $TLS subscribe --mode stream --stream-mode sample --sample-interval 10s \
  --path "native:/network-instance[name=*]/protocols/bgp/neighbor[peer-address=*]/session-state" \
  --path "native:/interface[name=*]/statistics"
gnmic $TLS subscribe --mode stream --stream-mode on-change \
  --path "native:/interface[name=*]/oper-state" --suppress-redundant --heartbeat-interval 60s
```
**Assert**: `once` returns data + `sync-response`; `sample` delivers ≥ 2 updates; keep the path
count ≤ 36 (`max-paths-per-subscription-request`).

### G8 — BGP EVPN / VXLAN route behaviour (the substantive gate)

After the default fabric intent is applied:

```bash
# 1. underlay + overlay sessions established
gnmic $TLS get --path "/network-instance[name=default]/protocols/bgp/neighbor[peer-address=*]/session-state"
# expect: "established" for every configured neighbor

# 2. the VTEP tunnel exists and is active  (equivalent CLI: show tunnel vxlan-tunnel all)
gnmic $TLS get --path "/tunnel/vxlan-tunnel"
gnmic $TLS get --path "/tunnel-interface[name=vxlan1]/vxlan-interface[index=1]/oper-state"
# expect: "up"; oper-down-reason absent

# 3. Type-2 MAC/IP: a remote MAC learned via EVPN in the mac-vrf bridge table
gnmic $TLS get --path "/network-instance[name=vlan100]/bridge-table/mac-table/mac[address=*]"
# expect: at least one entry with type "evpn"

# 4. Type-3 inclusive-multicast: the remote VTEP appears as a destination
gnmic $TLS get --path "/tunnel-interface[name=vxlan1]/vxlan-interface[index=1]/bridge-table/multicast-destinations"

# 5. EVPN RIB actually carries routes
gnmic $TLS get --path "/network-instance[name=default]/bgp-rib/afi-safi[afi-safi-name=evpn]"
```

Verified live equivalents `[LAB]`: `show network-instance default protocols bgp neighbor` →
`established`, `evpn [2/2/2]`, `ipv4-unicast [2/1/2]`; `show tunnel vxlan-tunnel all` →
`1 VXLAN tunnels, 1 active, 0 inactive`, VTEP `10.0.0.2`.

### G9 — ACL programming and applied-side read-back (replaces PC-13)

```bash
# write a filter + bind it to a SUBINTERFACE
gnmic $TLS set \
  --update-path "/acl/acl-filter[name=gate][type=ipv4]/statistics-per-entry" --update-value true \
  --update-path "/acl/acl-filter[name=gate][type=ipv4]/entry[sequence-id=10]/action/drop" --update-value '{}' \
  --update-path "/acl/interface[interface-id=ethernet-1/1.0]/interface-ref/interface" --update-value "ethernet-1/1" \
  --update-path "/acl/interface[interface-id=ethernet-1/1.0]/interface-ref/subinterface" --update-value 0
# applied-side read-back, scoped to THIS service's filter and entry
gnmic $TLS get --path "/acl/interface[interface-id=ethernet-1/1.0]"
gnmic $TLS get --path "/acl/acl-filter[name=gate][type=ipv4]/entry[sequence-id=10]/statistics"
```

Verified live `[LAB]` — the read-back returns exactly:
```json
"srl_nokia-acl:acl/interface": {
  "interface-ref": { "interface": "ethernet-1/1", "subinterface": 0 },
  "output": { "acl-filter": [ { "name": "blockicmp", "type": "ipv4" } ] } }
"srl_nokia-acl:acl/acl-filter/entry/statistics": { "last-match": "…", "matched-packets": "3" }
```

**This closes R-26.** On SONiC the implemented applied-side check was *switch-wide* and a stock leaf
passed it vacuously. On SR Linux the applied state is **keyed by `interface-id` and by
`[name][type]` + `sequence-id`**, so a correctly-scoped two-sided check is trivially expressible and
there is no stock entry to false-positive against. FR-042's two-sided read-back should be rewritten
against these two paths.

### G10 — What the gate must NOT check any more

Delete from PC-02 / PC-04 / quickstart §1: SRv6 IPv6 forwarding, SRH processing, SID-list and
steering programming, `H.Encaps.Red` headend, `End` transit, `End.DT46` endpoint, native
`sonic-srv6` YANG over Set/Get, MySID flex counters, and the `sonic-vm` fallback sentence. None has
an SR Linux substrate on a license-free type (§2.4). **PC-N-11's "a failed capability is never
skipped" rule still stands, and that is precisely why these must be deleted rather than marked
skipped.**

---

## 8. MTU — measured, and why the constitution's numbers must change

### 8.1 The SR Linux MTU model

`[VERIFIED: …/interfaces/srl_nokia-interfaces.yang:838-1397; …/system/srl_nokia-mtu.yang:73-130]`

| Leaf | Scope | YANG range | System default | 7220 IXR platform max |
|---|---|---|---|---|
| `/interface[name]/mtu` | port, **includes Ethernet header, excludes FCS** | `1450..9500` | `9232` | **9412** |
| `/interface/subinterface/ip-mtu` | **includes IP header, excludes Ethernet** | `1280..9486` | **`1500`** | **9398** |
| `/interface/subinterface/l2-mtu` | bridged subif, includes Eth hdr + VLAN tags, excl. FCS | `1450..9500` | `9232` | **9412** |
| `/interface/subinterface/mpls-mtu` | — | `1284..9496` | `1508` | n/a (no MPLS) |
| `/system/mtu/min-path-mtu` | — | `552..9232` | `552` | |

Live read of `/system/mtu` on 26.7.2 `[LAB]`:
`{"default-ip-mtu": 1500, "default-l2-mtu": 9232, "default-port-mtu": 9232, "min-path-mtu": 552}`

**The platform maxima are enforced at commit, not just documented.** Exact rejections `[LAB]`:

```
$ gnmic … set --update-path /interface[name=ethernet-1/1]/mtu --update-value 9500
  InvalidArgument … [InvalidArgument] mtu 9500 out of range [1500-9412]
$ gnmic … set --update-path "/interface[name=ethernet-1/1]/subinterface[index=0]/ip-mtu" --update-value 9399
  InvalidArgument … [InvalidArgument] 9399 out of range [1280-9398]
```
`mtu 9412` and `ip-mtu 9398` both committed successfully.

**⚠️ The default `ip-mtu` is 1500.** A jumbo underlay requires *explicitly* setting both the port
`mtu` and every routed subinterface's `ip-mtu`. Raising the port MTU alone does nothing.
`mtu` / `ip-mtu` / `mpls-mtu` are **not configurable on `system0` or `lo<N>`**
(`must "not (starts-with(…, 'system') or starts-with(…, 'lo'))"`), and port `mtu` is not
configurable on `irb<N>` — for IRB, set the subinterface `ip-mtu`.

### 8.2 Containerlab veth MTU

- containerlab sets **9500 B on every data veth by default**
  `[VERIFIED: containerlab/docs/manual/network.md:413]`; confirmed live on both link ends `[LAB]`.
  **9500 > 9412, so the veth is never the binding constraint** for a 7220 IXR fabric. Per-link
  `mtu:` in the topology is therefore unnecessary — **omit it** and let the device model own the
  number.
- The **management** bridge follows the Docker network MTU (1500 by default; containerlab reports
  `MTU=0` when creating unless `mgmt.mtu` is given) `[LAB]`.

### 8.3 Measured VXLAN arithmetic — the authoritative numbers

Lab: `leaf01`(d2l) ↔ `leaf02`(d2l) back-to-back on `ethernet-1/49`, eBGP + EVPN, `mac-vrf vlan100`,
VNI 100, VTEPs `system0.0` = 10.0.0.1 / 10.0.0.2, underlay `mtu 9412` + `ip-mtu 9398`, access
`ethernet-1/1` `mtu 9412` + `l2-mtu 9412`. `[LAB]`

**tcpdump on the fabric link, sending `ping -M do -s 9320`:**

```
18:12:01 1a:f6:… > 1a:98:…, ethertype IPv4, length 9412: 10.0.0.1.51551 > 10.0.0.2.4789: VXLAN, flags [I], vni 100
        00:c1:ab:00:00:01 > 00:c1:ab:00:00:02, ethertype IPv4, length 9362: 192.0.2.11 > 192.0.2.21: ICMP echo request, length 9328
```

So, exactly:

```
outer Ethernet frame on the wire ........ 9412   = the port MTU, to the byte
  − outer Ethernet header ...... 14
  = outer IPv4 packet ................... 9398   = the ip-mtu maximum, to the byte
  − outer IPv4 header .......... 20
  − UDP header (dport 4789) .....8
  − VXLAN header ................8
  = inner Ethernet frame ................ 9362
  − inner Ethernet header ...... 14
  = inner IP packet (tenant MTU) ........ 9348
```

**Ping sweeps confirming the boundary to the byte `[LAB]`:**

| IPv4 `ping -M do -s N` | N=9319 | **N=9320** | N=9321 |
|---|---|---|---|
| inner IP total (N+28) | 9347 | **9348** | 9349 |
| result | OK | **OK** | **FAIL** |

| IPv6 `ping6 -M do -s N` | N=9299 | **N=9300** | N=9301 |
|---|---|---|---|
| inner IP total (N+48) | 9347 | **9348** | 9349 |
| result | OK | **OK** | **FAIL** |

**The single formula to put in the data model:**

```
tenant inner-IP MTU  =  underlay port MTU  −  50 (outer Eth 14 + IPv4 20 + UDP 8 + VXLAN 8)
                                           −  14 (inner Ethernet header)
                     =  underlay port MTU  −  64
```

(Add 4 more if the inner frame is 802.1Q-tagged; SR Linux's `l2-mtu` "includes the Ethernet header
and VLAN tags".) **The v4/v6 distinction is not in the encapsulation** — both tenant families are
bounded by the same 9348-byte inner IP packet; they differ only in header size (20 vs 40), so the
*payload* numbers differ while the *MTU* does not.

### 8.4 Recomputed numbers vs. the constitution

| Quantity | Constitution / PC-19 (SONiC) | **SR Linux, measured** |
|---|---|---|
| Underlay L3 MTU | 9216 | **9412** port MTU / **9398** `ip-mtu` (platform maximum on 7220 IXR) |
| VXLAN overhead | "50 over IPv4, 54 over IPv6" | **50** over IPv4. **There is no IPv6 underlay** (§2.4) — the "54" number has no SR Linux meaning and must be deleted |
| "Effective tenant payload" | 9166 (v4) / 9162 (v6) | Those are *inner Ethernet frame* sizes (9216−50). SR Linux equivalent at a 9412 underlay: **inner Ethernet frame 9362**, **tenant IP MTU 9348** |
| Acceptance ping payload | (implied 9166/9162) | **IPv4 `ping -s 9320`** / **IPv6 `ping6 -s 9300`** — both verified to pass at that size and fail one byte above |
| SRv6 overhead / ~9120 with 3 SIDs | present | **delete** — no SRv6 substrate (§2.4) |

If the spec prefers to keep the round **9216** underlay for continuity, the derived numbers become
(by the same formula, **not measured**): inner Ethernet frame **9166**, tenant IP MTU **9152**,
IPv4 ping payload **9124**, IPv6 ping payload **9104**. *Recommendation*: don't — use the platform
maximum 9412 and the measured 9348/9320/9300, because those are the numbers a reader can reproduce
with the commands in this report.

> **Proposed data-model §20 replacement**
>
> **MTU and overhead (lab defaults)**: underlay port MTU **9412** (the 7220 IXR maximum; the
> emulated port `mtu` leaf rejects 9413 and above) with routed-subinterface `ip-mtu` **9398** and
> bridged-subinterface `l2-mtu` **9412**. VXLAN encapsulation adds **50 bytes** over an IPv4
> underlay (outer Ethernet 14 + IPv4 20 + UDP 8 + VXLAN 8); the inner Ethernet header costs a
> further 14. Effective tenant IP MTU is therefore **9348** for both IPv4 and IPv6 — the VXLAN
> underlay is IPv4-only on this platform, so there is no separate IPv6-underlay figure. Acceptance
> packets are sized at **`ping -M do -s 9320`** (IPv4) and **`ping6 -M do -s 9300`** (IPv6), each
> one byte below the observed drop threshold. Linux endpoint interfaces MUST be set to MTU 9348 or
> lower; leaving them at the containerlab veth default of 9500 blackholes TCP entirely (§9.4).

### 8.5 ⚠️ `mgmt.mtu` is a trap — do not set it

The existing SONiC topology sets `mgmt.mtu: 9216`. On SR Linux this **silently fails**.

Containerlab emits `set / interface mgmt0 subinterface 0 ip-mtu {{ .MgmtIPMTU }}` where
`MgmtIPMTU = n.Runtime.Mgmt().MTU` `[VERIFIED: srl.go:706-724]` — but it does **not** raise
`interface mgmt0 mtu` (which defaults to 1514 and caps at 9216). With `mgmt.mtu: 9500` I observed
`[LAB]`:

```
$ docker exec … grep -i mtu /tmp/clab-default-config
set / interface mgmt0 subinterface 0 ip-mtu 9500
$ docker exec … sr_cli -d 'info from state / interface mgmt0 subinterface 0 ip-mtu'
    ip-mtu 1500                       ← the line was rejected and dropped
$ sr_cli -ed 'set / interface mgmt0 subinterface 0 ip-mtu 9500'
  Error: … Must be an integer in range 1280..9486
```

The rest of the default config (TLS, gRPC, JSON-RPC) still applied, so the failure is **silent and
partial** — gNMI works and nothing warns you. **`mgmt.mtu: 9216` would be accepted by the YANG range
but is still inconsistent with the un-raised `mgmt0 mtu 1514`.** Management traffic is TCP (gNMI,
JSON-RPC, SSH); MSS clamping handles it. **Omit `mgmt:mtu` entirely.**

---

## 9. Containerised-dataplane limits an acceptance test must not trip over

### 9.1 Throughput / PPS ceiling — the biggest one

Containerlab documents *"the datapath is limited to 1000 PPS"* in license-free mode
`[VERIFIED: containerlab/docs/manual/kinds/srl.md:414]`. **Measured behaviour is different and
more permissive**, through a two-leaf VXLAN path with 1400-byte UDP datagrams `[LAB]`:

| offered | received | loss |
|---|---|---|
| 5 Mbit/s (≈ 446 pps) | 5.00 Mbit/s | **0 %** |
| 20 Mbit/s (≈ 1 786 pps) | 20.0 Mbit/s | **0 %** |
| 50 Mbit/s (≈ 4 465 pps) | 50.0 Mbit/s | **0 %** |
| 80 Mbit/s (≈ 7 143 pps) | 55.1 Mbit/s | 31 % |
| 100 Mbit/s (≈ 8 930 pps) | 56.1 Mbit/s | 44 % |
| 200 Mbit/s (≈ 17 857 pps) | 56.1 Mbit/s | 72 % |

The knee is at **≈ 5 000 pps / ≈ 56 Mbit/s at 1400 B**. TCP with a correct MTU reached
**261 Mbit/s** (larger frames, ~3.5 kpps). `ping -c 3000 -i 0.001` ran with 0 % loss at ~930 pps.

**Requirement wording**: any acceptance test asserting reachability MUST use low-rate, bounded
traffic (single pings, `-c N` with `-i ≥ 0.01`), and MUST NOT assert throughput or use `ping -f`.
SC-004's "100 % of expected BGP sessions" and the Type-2/3 route assertions are unaffected; any
future bandwidth assertion is not portable.

Also: **`sr_linux` restarts once a week** in license-free mode. A CI lab is fine; a soak >7 days
will see an unexplained control-plane restart.

### 9.2 ACLs **are** enforced and counters **do** work — verified

This was the single load-bearing unknown. Test `[LAB]`: an **egress** (`output`) IPv4 filter on
`leaf02:ethernet-1/1.0` (a **bridged** subinterface), `subinterface-specific` left at default
`disabled`, `statistics-per-entry true`, dropping ICMP from `192.0.2.11/32`:

```
$ ping -c3 192.0.2.21       → 3 packets transmitted, 0 received, 100% packet loss
$ sr_cli -d 'info from state acl acl-filter blockicmp type ipv4 entry 10 statistics'
    matched-packets 3
    last-match "2026-09-20T14:12:33.000Z (2 seconds ago)"
```

Same state read over gNMI returns `{"last-match": "…", "matched-packets": "3"}` (note: **uint64
counters come back as JSON strings** under `JSON_IETF`). `[LAB]`

Caveats:
- **Counters lag.** A parallel probe saw `matched-packets 0` immediately after traffic and the real
  value seconds later. **Acceptance tests must poll with a bounded retry, not read once.**
- The **leaf name differs by release**: 26.7 exposes `statistics/matched-packets`; the 25.3 ACL
  guide documents `statistics/aggregate/in-matched-packets`. `[LAB + VERIFIED via parallel probe]`
  **Pin the path to the pinned release and cover it in the FR-017 path register.**
- With `subinterface-specific disabled`, the *per-interface* statistics container is empty — only
  the per-filter-entry counters populate.
- `/acl/egress-mac-filtering true` is required before any **MAC** filter may be bound egress on the
  D-series (§2.5).

### 9.3 What is present vs. absent in the container

| Capability | Container status |
|---|---|
| EVPN-VXLAN L2 (mac-vrf) + L3 (ip-vrf/IRB) | **Works** — proved end to end `[LAB]` |
| EVPN multihoming / ESI-LAG | `evpn-mh`, `evpn-mh-anycast`, `evpn-mh-virtual-es`, `evpn-mh-ip-aliasing` all present on d2l/d3l/d5 `[LAB]`; Nokia ships a container EVPN-MH tutorial `[VERIFIED: /root/learn-srlinux/docs/tutorials/evpn-mh/]`. **Absent on H-series** |
| ACL enforcement + per-entry counters | **Works** (§9.2) |
| Mirroring | `mirroring`, `mirror-dest-local/remote`, `mirror-source-acl/intf/subintf` present on d2l/d3l/d5 `[LAB]`; *"SR Linux container image is built with mirroring support"* `[VERIFIED: /root/learn-srlinux/docs/blog/posts/2024/mirroring.md]`. **Absent on h4** |
| sFlow | `sflow` feature present; **in-container sampling behaviour undocumented** `[UNVERIFIED]` |
| QoS | `qos*` features present; **rate enforcement untestable under the ~5 kpps ceiling** |
| Interface / VXLAN statistics | present; `vxlan-stats` on d2l/d3l but **not d5** `[LAB]` |
| `tools` commands | work (`tools system configuration save` is what containerlab itself runs) |
| `docker stats` | **returns zeros** — read cgroups instead `[LAB]` |
| Multiple line cards | **not supported by containerlab** — only `ethernet-1/N` `[VERIFIED: containerlab docs]` |
| `vsrl` YANG restrictions (BFD ≥ 1 s, ECMP ≤ 16, no ACL policer stats, no optics telemetry) | **DO NOT APPLY** — neither `vsrl` nor `platform-vsrl` is set on any containerlab 7220 node `[LAB]` |
| Factory ACL baseline | **differs from hardware**: containerlab re-adds CPM allow rules for HTTP/80 and Telnet/23 (v4+v6, entries 88/98/158/128/138/188) plus 358/368 for tcp/57401 and 355/356/357 + 365/366/367 for EDA. Any test asserting "factory default ACL state" must account for these `[VERIFIED: containerlab/nodes/srl/version_configs/acl.cfg, grpc.cfg, eda_configs/]` |

### 9.4 ⚠️ TCP blackholes if endpoint MTU exceeds the tenant MTU

With `client01`/`client02` `eth1` at the containerlab default **9500**, `iperf3` TCP transferred
**0 bytes** (sender 419 Kbit/s of retransmits, receiver nothing) — a classic PMTUD blackhole,
because the overlay drops the oversize frames and SR Linux does not originate an ICMP "frag needed"
back to the host across the bridged service. Setting both clients to **9348** immediately gave
**261 Mbit/s**. `[LAB]`

**This must be in the topology file and in the quickstart**: endpoint `exec:` lines must include
`ip link set dev eth1 mtu 9348`. A test that only pings will not catch it.

### 9.5 Packet capture on clab links

Verified working `[LAB]` — from the host, enter the node's network namespace by PID:

```bash
PID=$(docker inspect -f '{{.State.Pid}}' clab-<lab>-leaf01)
nsenter -t "$PID" -n tcpdump -nn -e -i e1-49 'udp port 4789'
```

Notes:
- The interface name in the capture is the **Linux** form (`e1-49`), not `ethernet-1/49`.
- The data interfaces live in the container's **root** netns; the routing/mgmt stacks live in
  `srbase-default` / `srbase-mgmt` (`ls /run/netns` inside the container shows
  `srbase, monit, srbase-default, srbase-mgmt` `[LAB]`). Capture data-plane traffic in the root
  netns; use `ip netns exec srbase-default ping …` for control-plane reachability tests.
- `tcpdump -e` decodes VXLAN natively and prints both the outer and inner frame lengths — which is
  exactly how the §8.3 numbers were obtained, and is the recommended evidence form for the
  MTU acceptance test.
- containerlab also offers `containerlab tools netem` and Edgeshark integration; neither was needed.

---

## 10. Licensing / legal

**The image is freely pullable and freely usable for a lab, with no registration.**

- Nokia's `srlinux-container-image` repo: *"Nokia made SR Linux container image publicly available
  to everyone with no registration, licensing or contract requirements"*; described as *"Freely
  distributed official SR Linux container image"* for *"learning, demo, test and CI environments"*;
  the repo itself is **BSD-3-Clause**.
  `[VERIFIED: https://github.com/nokia/srlinux-container-image]`
- containerlab: *"SR Linux is the first commercial Network OS with a free and open distribution
  model. Everyone can pull SR Linux container from a public registry."*
  `[VERIFIED: containerlab/docs/manual/kinds/srl.md:17]`
- Pulled anonymously with both `skopeo` and `docker pull` this session — no credentials needed.
  `[LAB]`
- The license-free mode carries the 1000 PPS / weekly-restart limits (§2.3, §9.1) and excludes the
  chassis-based types — neither affects a 7220 IXR lab.
- **Redistribution**: the BSD-3 licence covers the *repository*, not necessarily the binary image
  layers. I found **no explicit statement granting redistribution of the image itself**
  `[UNVERIFIED]`. **Recommendation**: pull from `ghcr.io/nokia/srlinux` by digest at provisioning
  time; do **not** re-host the image in a private registry as part of this project. The existing
  SONiC design's `localhost:5000` local-registry pattern should be dropped for SR Linux — it is
  unnecessary (the upstream registry is public and unauthenticated) and it is the one action that
  would raise a redistribution question.

**The spec Assumption *"A device image containing the required management and EVPN functions is
legally obtainable and can be pinned"* holds without qualification.** The second sentence of that
assumption — *"If the fast profile fails EVPN or SRv6 qualification, another pinned profile that
passes the unchanged gate is the conformance target"* — should be deleted (§5.4).

---

## 11. Coupling-by-coupling disposition

| Coupling | Disposition |
|---|---|
| **PC-01** image/digest/compatibility set | **Rewritten.** §1.4, §1.6, §1.7. Five-part set becomes four: image digest, YANG tag (same version string as the image), sdcio Schema CR + deviations branch, containerlab version |
| **PC-02** capability gate content | **Rewritten.** §7 G1–G9. SRv6 items deleted, not translated |
| **PC-03** fast vs conformance VM profile | **Deleted.** §5. No VM tier exists, no KVM requirement exists, the container passes EVPN qualification. `--profile` flag removed from `provision.sh`/`off.sh` |
| **PC-18** "SONiC 202505 and FRR 10.3" | **Replaced** by "SR Linux 25.7.1 (or 26.7.2)". FRR has no successor — SR Linux's BGP is native. **PC-17 (the FRR IPv6 IRB Type-5 defect) has no successor and should be deleted, not translated** |
| **PC-19** MTU numbers | **Rewritten.** §8.4. 9412 / 9398 / 9348 / ping 9320 & 9300. The IPv6-underlay "54-byte" figure is deleted because the platform has no IPv6 VXLAN |
| **PC-A-01** node kinds and interface naming | **Rewritten.** kind `nokia_srlinux`, type `ixr-d2l`/`ixr-d3l`, `ethernet-1/N`. §3.5. Node roles and the 2×2 + 4 endpoints shape survive; `srv6-client01/02` become `client03/04` |
| **PC-A-03** operator-facing gate checklist | **Rewritten.** §7 is the new quickstart §1 list. The `sonic-vm` fallback block is deleted |
| **PC-A-06** mgmt CIDR / addresses / port | CIDR `172.31.0.0/16` and `.11 .12 .21 .22` **survive mechanically** (§4.5 proves `mgmt-ipv4` + pre-created network works), but ⚠️ **collide with an existing Docker network on this host** (§4.6). The gNMI port becomes **57400**, and **57401 must also be denied** by the NetworkPolicy — otherwise the safety boundary has a plaintext bypass |
| **PC-A-13** lifecycle script phases and flags | **`--profile` deleted** (§5.4). Everything else — idempotence, ownership checks, single path, the labelled Docker network — survives unchanged. Add a Docker-network-overlap check to preflight; replace the `docker stats` resource probe with a cgroup read |
| **PC-A-02 / spec §OD-4** (adjacent, but decided here) | ACLs bind to **subinterfaces**. FR-037 and FR-043 both rewrite; the unit of exclusivity becomes "a subinterface at a stage" |
| **spec §OD-3** SRv6 (adjacent, decided here) | **Drop to a future feature.** No license-free containerlab type has SRv6 services; H5 has transit-only uSID and no EVPN-VXLAN |
| **spec §OD-5** construct vocabulary (adjacent) | SR Linux names its instances **`mac-vrf`** and **`ip-vrf`** natively; the vocabulary stops being a translation layer |

---

## 12. Reproduction commands

Everything above can be re-derived with:

```bash
# tags and digests
skopeo list-tags docker://ghcr.io/nokia/srlinux
docker buildx imagetools inspect ghcr.io/nokia/srlinux:26.7.2
skopeo inspect --raw docker://ghcr.io/nokia/srlinux:25.7.1 | sha256sum

# YANG ground truth
git clone --depth 1 --branch v26.7.2 https://github.com/nokia/srlinux-yang-models

# containerlab's SRL behaviour
git clone --depth 1 --branch v0.79.0 https://github.com/srl-labs/containerlab
less containerlab/nodes/srl/{srl.go,version.go,srl_default_config.go.tpl}
less containerlab/nodes/srl/version_configs/*.cfg
less containerlab/docs/manual/kinds/srl.md

# per-type feature and port inventory (the authoritative "feature matrix")
docker exec clab-<lab>-<node> sr_cli -d 'show interface brief'
gnmic -a <ip>:57400 --skip-verify -u admin -p 'NokiaSrl1!' -e json_ietf get --path /system/features

# MTU on the wire
nsenter -t $(docker inspect -f '{{.State.Pid}}' clab-<lab>-leaf01) -n \
  tcpdump -nn -e -i e1-49 'udp port 4789'
```

Scratch artifacts from this session (safe to delete):
`.../scratchpad/containerlab`, `.../scratchpad/yang`,
`.../scratchpad/{typeprobe,evpnmtu,netreuse}` (topology files only; all labs destroyed, all
Docker networks removed).
