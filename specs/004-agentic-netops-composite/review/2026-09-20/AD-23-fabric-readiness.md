# Review of AD-23 — `Fabric` readiness reads sessions and the reflection setting, never a route count

**Reviewer**: research agent (read-only; no existing file was modified, no checkbox ticked)
**Date**: 2026-09-20
**Decision under review**: `research.md:2351-2379` (AD-23), carried into
`spec.md:186-194` (User Story 1 scenario 2), `spec.md:863-877` (FR-100),
`spec.md:1528-1535` (SC-004), `spec.md:593-599` (edge case),
`data-model.md:200-212` (§3a), `contracts/reconciliation.md:106-112`,
`quickstart.md:283-309` (§4), `plan.md:709-717` (P2), `plan.md:781-786` (P3),
`plan.md:969` (SC-004), `plan.md:1110` (R-46), `tasks.md:173` (T041),
`tasks.md:185` (T051), `tasks.md:196` (T052), `tasks.md:228` (T064),
`traceability.md:372`, `traceability.md:430`.

**Sources used**: the pinned YANG models, cloned fresh for this review —
`github.com/nokia/srlinux-yang-models` tag `v25.7.1`, commit
`badcf9977fe672437907cdae7daebb27a1361c36` (matches the pin recorded at
`evidence/05-kubenet-sdc-kuid.md:851`), referenced below as `$Y` =
`<clone>/srl_nokia/models`; the local learn.srlinux.dev checkout `/root/learn-srlinux`;
Nokia release documentation fetched live (URLs given inline); and the repository's own
evidence files.

---

## Verdict

**RATIFY WITH AMENDMENTS.** Confidence: **high** on the factual premise (Q1) and on the
mechanics of the read-back (Q2, Q3); **medium-high** on the recommendation itself. AD-23's
central claim is correct and should stand: on SR Linux 25.7.1 a leaf with the EVPN family
negotiated but no `mac-vrf`/`ip-vrf` carrying `bgp-evpn` originates **no** EVPN route at all,
so "zero EVPN routes at `FabricReady`" is the correct state and a route assertion there would
have been either unsatisfiable or quietly weakened — exactly the failure Principle VI names.
The rejected canary is genuinely expensive and genuinely tenant-shaped, and rejecting it was
reasonable. **But the substitute invariant is weaker than the specification presents it as.**
`inter-as-vpn` is a *configuration* leaf (`$Y/network-instance/srl_nokia-bgp.yang:4467-4478`,
no `config false`), and Nokia's own definition of the state datastore is "the running
configuration, plus dynamically added data"
([documentation.nokia.com/srlinux/25-7/books/config-basics/configuration-management.html](https://documentation.nokia.com/srlinux/25-7/books/config-basics/configuration-management.html)).
Reading it back with `--type state` therefore proves only that the configuration was applied —
which the written side of FR-100 already proves — and proves nothing about reflection. Three
documents (`plan.md:296`, `plan.md:1110`, `data-model.md:200-212`) present that read as
*applied-side, device-state* evidence on a par with an oper-state read; it is not. The amendments
below (A1–A6) keep AD-23's decision intact, say plainly what the setting read is and is not,
and add three checks that are keyed, behavioural and essentially free — the per-neighbour EVPN
family `oper-state`, `route-reflector/client` on the spines, and underlay reachability of every
other node's `system0.0` loopback (which `spec.md:188-189` already promises and the read-back
does not deliver). One genuine defect was found in the compensating controls: the
`EvpnRoutesLost` alert (`evidence/06-telemetry-visualization.md:855-859`), cited by R-46 as a
mitigation, fires *continuously* during precisely the window AD-23 blesses.

---

## Q1 — Is the factual premise true? Zero EVPN routes with sessions up and no EVPN instance?

**YES, on this platform and in this design's scope — VERIFIED, with one bounded caveat.**

1. **EVPN route origination is structurally bound to an EVPN instance.** The `bgp-evpn`
   configuration subtree is `list bgp-instance` inside `grouping bgp-evpn-top`
   (`$Y/network-instance/srl_nokia-bgp-evpn.yang:553-620`), augmented at
   `/network-instance/protocols/bgp-evpn` (`$Y/network-instance/srl_nokia-bgp-evpn.yang:707`) —
   i.e. it exists only *inside* a network-instance. `leaf evi` is `mandatory true`
   (`:606-618`) and is what the route distinguisher and route target are derived from. With no
   `mac-vrf` and no `ip-vrf` there is no `bgp-evpn bgp-instance`, therefore no EVI, no RD and no
   RT, therefore nothing to originate.
2. **Type-3/IMET specifically.** *"The IMET route is advertised as soon as bgp-evpn is enabled in
   the MAC-VRF"* [`/root/learn-srlinux/docs/tutorials/l2evpn/evpn.md:729`]. The converse is shown
   by the vendor's own L3-only tutorial, where an `ip-vrf`-only fabric reports
   `0 Inclusive Multicast Ethernet Tag routes 0 used, 0 valid`
   [`/root/learn-srlinux/docs/tutorials/l3evpn/rt5-only/l3evpn.md:198`,
   `:227`] — origination is per instance type, not per session.
3. **Type-2 and Type-5** likewise require a bridge table / route table inside an EVPN-enabled
   instance; neither exists.
4. **The spines originate nothing by construction.** They carry no `mac-vrf`, no `ip-vrf` and no
   `tunnel-interface` (`evidence/02-evpn-constructs.md:107-110`; `plan.md` P3 and quickstart §4
   both assert "no tenant VTEP, bridged instance or routed instance on a spine").
5. **Caveat — the one family that is *not* instance-bound.** EVPN **Type-4 (Ethernet Segment)**
   and **Type-1 (Ethernet A-D per ES)** routes hang off a different subtree entirely,
   `/system/network-instance/protocols/evpn/ethernet-segments/bgp-instance[id]/ethernet-segment[name]`
   (`evidence/02-evpn-constructs.md:1590-1598`, citing
   `$Y/system/srl_nokia-system-network-instance-bgp-evpn-ethernet-segments.yang:426-660`).
   An ES configured with no `mac-vrf` would originate an ES route. **This does not bite here**:
   EVPN multihoming is explicitly out of scope (`spec.md:1888`;
   `evidence/02-evpn-constructs.md:1360`, `:1588-1626`: *"No ESI is ever claimed"*), and
   `evidence/02-evpn-constructs.md:1611` records that the `ethernet-segment-route` (Type 4) and
   `ethernet-ad-route` (Type 1) RIB lists stay empty. The premise is therefore true **given the
   declared scope**, and it is the scope, not the platform, that makes it true. AD-23 does not
   say so; amendment **A5** proposes that it should, so that a future multihoming feature does
   not silently invalidate the rationale.

**Conclusion**: AD-23's rationale — "a device originates an EVPN route only for an EVPN instance,
so at that moment zero routes is the *correct* state" (`research.md:2363-2366`) — is factually
sound. Had `FabricReady` retained a route assertion, it could only have been satisfied by
leaving the gate's scratch instances in place (which `tasks.md:175` forbids: the gate reads its
own removal back before it reports) or by weakening the check. Rejecting that was right.

---

## Q2 — `inter-as-vpn`: readable from state? config-mirrored? really required? what would the read miss?

### 2a. The path is correct and the leaf exists at the pin — VERIFIED

`/network-instance[name=default]/protocols/bgp/afi-safi[afi-safi-name=srl_nokia-common:evpn]/evpn/inter-as-vpn`
resolves in the pinned model as `grouping bgp-top` → `container bgp`
(`$Y/network-instance/srl_nokia-bgp.yang:3654`) → `list afi-safi` (`:4039`) →
`container evpn` (`:4427`) → `leaf inter-as-vpn` (`:4467-4478`). It is `type boolean`,
`default "false"`, with a `must` confining EVPN to the `default` network-instance, and **no
`if-feature`** — so it is unconditionally available on this image. The identity `evpn` is
defined in module `srl_nokia-common` (`$Y/common/srl_nokia-common.yang:1723`, base
`bgp-address-family` at `:1678`), which is why the quickstart's `srl_nokia-common:evpn`
qualifier is the right JSON_IETF form — subject to G12, which exists to confirm exactly this.

Note the leaf is **instance-level only**: the group-level and neighbour-level `container evpn`
(`:1083`, `:2510`) have no `inter-as-vpn`. Per-spine, one read.

### 2b. It is a config leaf mirrored in state — so the read-back proves application, not reflection — VERIFIED

`leaf inter-as-vpn` carries no `config false` (`$Y/network-instance/srl_nokia-bgp.yang:4467-4478`;
the file uses `config false` 71 times elsewhere, so its absence is meaningful). Nokia defines the
two datastores as: *"The running datastore contains the currently active configuration"* and
*"The state datastore contains the running configuration, plus dynamically added data such as the
operational state of interfaces or BGP peers added via auto-discovery, as well as session states
and routing tables."*
([documentation.nokia.com/srlinux/25-7/books/config-basics/configuration-management.html](https://documentation.nokia.com/srlinux/25-7/books/config-basics/configuration-management.html), fetched 2026-09-20).

**Therefore**: `get --type state .../inter-as-vpn` returns the configured value. It is a
config echo, not an observation of behaviour. Its marginal value over FR-100's written side
(`Config` applied, no deviation, content present in the **running** datastore) is limited to
catching an out-of-band deletion in the interval between reconciliations — which SDC's own
deviation detection and the revertive drift policy (`plan.md` P3, AD-13/AD-17) already catch.
This is exactly the epistemic shape of the predecessor defect `spec.md:109` warns about
("an applied-side check that passed on an empty fabric because it was switch-wide") in a
different guise: a check that cannot fail for the reason it is named after.

`plan.md:1110` (R-46) says the read is *"from the **state** of every reflecting spine, not from
what was written"* — emphasis in the original. On SR Linux that distinction does not exist for a
config leaf. `plan.md:296` (Principle I gate) and `data-model.md:200-212` make the same implicit
claim. This is the single most important thing the amendments should fix.

### 2c. Is `inter-as-vpn` really required on a non-VTEP RR spine? — stronger than research.md admits, but still not release-documented

Research Open item 4 (`research.md:2515-2520`) says the requirement *"comes from a vendor
engineer's writing rather than from release documentation."* That is still true of the
**requirement**, but the **mechanism** is now documented by Nokia and by the model itself:

- Nokia release documentation: *"The inter-as-vpn true command allows received EVPN/IP-VPN
  routes to be retained in the BGP RIB and propagated to any eBGP or iBGP peer"* and *"The
  inter-as-vpn true command has the same function as the keep-all-routes command for keeping the
  routes in the RIB"*
  ([documentation.nokia.com/srlinux/25-7/books/vpn-services/next-hop-self-route-reflector-and-inter-as-option-b.html](https://documentation.nokia.com/srlinux/25-7/books/vpn-services/next-hop-self-route-reflector-and-inter-as-option-b.html), fetched 2026-09-20).
  The page documents it on ASBRs and is **silent** on route reflectors with no local VPN service —
  it neither states nor denies the requirement. Open item 4 stands.
- The model text is the strongest written evidence: *"When set to true, received EVPN routes that
  are **not imported by any network-instance** are retained in the BGP RIB and considered 'used'
  so that they can be propagated to any EBGP or IBGP peer"*
  (`$Y/network-instance/srl_nokia-bgp.yang:4468-4472`). A spine with no `mac-vrf`/`ip-vrf` imports
  nothing, so *every* EVPN route it receives is in that set; with the leaf at its `default "false"`
  those routes are, by the leaf's own contrapositive, not retained and not propagated.
- The sibling confirms the negative: `keep-all-routes` retains them but *"these routes display as
  'rejected' and **cannot be propagated to other peers**"* (`:4441-4451`). So
  `keep-all-routes true` is a plausible, wrong, silent substitute — and AD-23's read-back, which
  names `inter-as-vpn` specifically, **does** catch that one. Credit where due.
- The operational framing remains the blog: `/root/learn-srlinux/docs/blog/posts/2024/srlinux-asymmetric-routing.md:701-703`.

**Verdict on 2c**: the requirement is near-certain from the model, empirically confirmed by
G8 and its negative control (`tasks.md:175`, `tasks.md:178`), and correctly kept as an open item.
No change to Open item 4 is needed beyond noting the model-text support (**A5**).

### 2d. What else produces "sessions up, zero routes reflected" that the AD-23 read-back would miss?

Ranked by likelihood on *this* design:

| # | Cause | Where in the model | Would AD-23's read-back catch it? |
|---|---|---|---|
| 1 | **`route-reflector/client` not `true` on the spine's overlay group.** The spine accepts routes from leaf01 and never reflects them to leaf02. Sessions established, EVPN family up, `inter-as-vpn true`, zero routes anywhere | `$Y/network-instance/srl_nokia-bgp.yang:1196-1209` (group), `:2629-2642` (neighbour). Config leaves — readable from state exactly as `inter-as-vpn` is | **No.** It is rendered (`tasks.md:156`, T027 golden) but not read back. This is the nearest-neighbour failure to the one AD-23 defends against, and closing it costs one extra `Get` path |
| 2 | **Underlay eBGP loopbacks not distributed.** `ebgp-default-policy/import-reject-all` and `export-reject-all` both `default "true"` (`$Y/network-instance/srl_nokia-bgp.yang:3947-3962`): an eBGP session with no explicit policy is established and carries nothing. Every `system0.0` /32 is then unreachable, overlay iBGP sessions to the loopbacks never come up — or, with a partial policy, come up while VTEP next-hops stay unresolved | `:3950-3955` | **Partly.** Overlay sessions failing to establish is caught. A policy that admits the overlay loopbacks but not the VTEP next-hops is not. `spec.md:188-189` already promises "system loopbacks are reachable" and neither `data-model.md:200-212` nor `tasks.md:173` reads it — see **A3** |
| 3 | **An import or export routing policy on the spine's EVPN family** dropping everything | `grouping bgp-afi-safi-policy` (`$Y/network-instance/srl_nokia-bgp.yang:185`), applied per afi-safi | **No** |
| 4 | **Extended communities stripped towards a peer** — the route target travels as an extended community; without it routes arrive and are never imported. `send-community-type` / `send-community` are per-neighbour/group | `:2370-2377` (leaf-list, feature-gated), `:2643-2657` (legacy container) | **No.** Produces "routes present, service never forms" rather than zero routes; caught later by the service's own `RoutesMissing` |
| 5 | **`rapid-update` false** (the `default`) | `:4478-4486` | **Irrelevant.** Its description is explicit that it only *"bypass[es] the session level min-route-advertisement-interval"* — it delays, it does not suppress. It is **not** a "zero routes" cause and should not be treated as one |
| 6 | **`keep-all-routes true` set instead of `inter-as-vpn true`** | `:4441-4451` | **Yes** — the read-back names `inter-as-vpn` |
| 7 | **Route-target constrain (`afi-safi-name=route-target`, RFC 4684)** enabled on the RR while the leaves advertise no RT membership | the `route-target` family exists in the afi-safi identity set and as a per-neighbour container (`:2560`) | **No**, but it is not rendered by this design, so the risk is brownfield-only |
| 8 | **`next-hop-self-route-reflector`** — worth noting as a *non*-issue: its description is explicit that it concerns *"received EVPN **MPLS** routes"* (`:4455-4465`). This design is VXLAN; it does not apply | `:4455-4465` | n/a |

**Net**: of the eight, the AD-23 read-back covers one (#6). #1 is the important gap, and it is
one YANG path away.

---

## Q3 — Reading "EVPN family negotiated" per neighbour on 25.7.1

**Exact path, VERIFIED in the pinned model:**

```
/network-instance[name=default]/protocols/bgp/neighbor[peer-address=<ip>]/afi-safi[afi-safi-name=srl_nokia-common:evpn]/oper-state
```

`leaf oper-state` is `config false`, an enumeration of `up`/`down`, whose `up` description is
literally *"Negotiated operational state of the address family is up"*
(`$Y/network-instance/srl_nokia-bgp.yang:2255-2267`, inside `list afi-safi` at `:2206` under
`list neighbor` at `:1850`). This is a **genuine** operational-state leaf — unlike
`inter-as-vpn` — and is the right evidence for the "EVPN family negotiated" half of
`tasks.md:173` / `data-model.md:200-212`.

Companions on the same list, all `config false`, useful for the route half and for the
`Network`'s `RoutesMissing`:
`received-routes` (`:2378-2383`), `sent-routes` (`:2384-2389`), `active-routes` (`:2390-2395`),
`rejected-routes` (`:2396-2401`) — note `rejected-routes` is exactly the counter that would be
non-zero on a spine with `keep-all-routes true` and `inter-as-vpn false`. Session state itself is
`leaf session-state`, `config false`, enum with `established` = 5
(`grouping neighbor-state`, `:1428-1453`). Instance-wide aggregates exist at `:4234-4245` and are
**not** admissible under FR-100 (unkeyed).

**Residual**: `quickstart.md:288-292` command **(a)** reads only
`/network-instance[name=default]/protocols/bgp/neighbor[peer-address=*]/session-state`, yet the
expectation two paragraphs down (`quickstart.md:301-302`) is *"`established` on every configured
neighbour **with the EVPN family negotiated**"*. The family read has no command anywhere in the
quickstart. See amendment **A4**.

---

## Q4 — The canary alternative, costed; and the cheaper middle options

### 4a. What the canary would cost

| Cost | Detail | Citation |
|---|---|---|
| A reserved VNI, permanently | The VNI allocation band is 10000–20000 on the `GENIDIndex` (`data-model.md:106`), and every VNI must be unique in its allocation scope and a subset of 1–65535 because `evi := vni` (`data-model.md:1010-1016`). A canary VNI must either be carved out of that band (shrinking it, and needing a reservation the authority enforces) or declared a fabric-wide constant outside it — in which case the CRD's CEL device-range rule and the authority's band rule now disagree about one value, and nothing stops a `Network` claiming it | `data-model.md:106`, `:1010-1016` |
| A `mac-vrf` per leaf with no subinterfaces | Technically it works — IMET is originated *"as soon as bgp-evpn is enabled in the MAC-VRF"*, with no attachment required (`/root/learn-srlinux/docs/tutorials/l2evpn/evpn.md:729`) — so the canary genuinely would prove reflection. But it is a tenant-shaped object with no `Network` behind it, and `data-model.md` §13's read-back table is written per *construct*, so a canary needs a row of its own or it is unreadable by the rules the platform already has | `data-model.md:744-770` |
| Allocation-authority impact | FR-012 lets a device identifier be *"a deterministic function of an allocated value, the service identifier or a fabric-wide constant"* — so a constant canary VNI is formally admissible, but FR-012 also makes the authority the owner of VNI allocation, so the reservation has to be real, not conventional | `spec.md:777-784` |
| A second renderer of bridged instances | Not an FR-014 violation — FR-014 requires a single *provider*, and both reconcilers live in one binary (`plan.md:457`) — but it does duplicate the `mac-vrf` render path into `controllers/fabric`, doubling the golden-file surface (T027 and the construct goldens) and the schema-validation surface | `spec.md:796-799`, `plan.md:457` |
| FR-029 interaction | None directly: the canary is a `mac-vrf`, not a `vlan`. But FR-029 exists precisely so that "local" is never encoded as "the overlay fields are missing", and a fabric-owned EVPN instance that belongs to no construct is the mirror-image category error | `spec.md:972-976` |
| Operator-visible surface | `quickstart.md` §4's expected output — *"no tenant VTEP, bridged instance or routed instance on a spine"* — stays true (leaves only), but every `show network-instance` on a leaf now lists an instance no service owns, and `data-model.md` §13's negative control (`quickstart.md:656-666`, "against a stock node that carries no tenant service") gets harder to write honestly | `quickstart.md:283-292`, `:653-670` |

### 4b. What it would prove that AD-23 cannot

Exactly one thing, and it is not nothing: **that route reflection works on the fabric the
provider rendered**, rather than on the scratch configuration the gate wrote. G8 runs *before*
`FabricReady`, on the gate's own scratch instances, which `run_gate.sh` then removes and reads
back (`tasks.md:175`; ordering at `plan.md:625-626`). So today nothing ever proves reflection on
the provider's own render until the first `Network` arrives. That gap is R-46 (`plan.md:1110`),
stated accurately.

It would also close #1 and #3 of the Q2d table (RR client, EVPN policy) behaviourally rather
than by configuration read-back.

### 4c. Middle options, assessed

- **A transient probe owned by verification tooling that gates `Fabric` readiness — NOT
  AVAILABLE.** FR-108 forbids it in terms: *"no service, fabric or lifecycle outcome depends on
  it — provisioning a service, converging the fabric and setting readiness use only the path of
  FR-014 and FR-015"* (`spec.md:914-926`). A probe under FR-108 can never be an input to
  `Fabric.status`. This should be said plainly in AD-23 so the option is not re-proposed.
- **A transient probe as an *acceptance* step — AVAILABLE and cheap. Recommended (A6).** Run
  G8's route-exchange proof a second time, *after* the fabric `Config`s are applied and before
  any `Network` exists, as a declared FR-108 step inside `tests/integration/fabric_verify.sh`
  (`tasks.md:185`, T051): apply a scratch `mac-vrf` on each leaf, observe RT3 received through
  the spines, remove it, read the removal back. Reported, evidence-captured, **not** an input to
  `Ready`. This closes R-46 almost entirely for the cost of one scratch instance pair per run,
  with no reserved VNI (the scratch EVI can be the gate's, since it is removed in the same run),
  no second renderer and no permanent object. It is the canary's benefit without the canary's
  cost.
- **Fabric readiness as AD-23 + the FIRST spanning service's negative control made mandatory —
  ALREADY THE CASE, but under-guarded.** `tasks.md:228` (T064) and `plan.md:781-786` (P3 gate)
  already require the negative control *preceding* the assertion. What is missing is (i) the
  operator-facing walkthrough never mentions it (`quickstart.md` §8, lines 402-418, has no
  "negative control" or "injected fault" text — the only occurrences in the file are
  `:653` for the keyed-read controls and `:1114` generically), and (ii) nothing states that
  `FabricReady` alone is inadmissible as SC-004 evidence. `spec.md:1530-1535` and `plan.md:969`
  say it; the acceptance script should enforce it. See **A6**.

**Recommendation on Q4**: do **not** adopt the canary. Adopt the transient post-render probe
(A6) plus the two free read-backs (A2, A3). That combination proves more than AD-23 does today,
costs less than the canary, and leaves no permanent object on any leaf.

---

## Q5 — Does AD-23 weaken Principle I or VI?

### The case that it does

- Principle I: *"`Ready=True` MUST reflect current live fabric state verified on devices"* and
  *"Status conditions MUST name the specific missing invariants (**routes**, VTEPs, BGP sessions,
  data path)"* (`.specify/memory/constitution.md`, Principle I bullets 2 and 4). AD-23 removes
  routes from the `Fabric`'s invariant set entirely. Of the three invariants that remain, two
  (interfaces, sessions) are true operational state; the third — the one carrying the whole
  weight of the reflection claim — is, as established in Q2b, **a re-read of the platform's own
  write**. `data-model.md:766-770` states the project's own standard for this: the device's
  `*-origin` leaves *"are what makes the route-distinguisher and route-target checks genuine
  applied-side assertions rather than a re-read of the platform's own write."* By that standard
  the `inter-as-vpn` read is not a genuine applied-side assertion, and `plan.md:296` presenting
  it in the Principle I gate as one overstates it.
- There is a real window: from `FabricReady` until the first spanning `Network`, the platform
  reports a healthy fabric on evidence that cannot distinguish "reflection works" from
  "reflection is configured". In a lab that window is minutes; the principle does not scale its
  requirement to the window's length.
- `spec.md:188-189` (User Story 1 scenario 2) promises *"system loopbacks are reachable"* and
  no read-back in `data-model.md:200-212`, `contracts/reconciliation.md:106-112` or
  `tasks.md:173` reads that. That is a Principle I gap AD-23 did not create but now carries.

### The case that it does not

- Principle VI is explicit: *"A gate MUST NOT be waived to make a run pass; if a gate cannot hold,
  the limitation is documented and the affected service reports `Ready=False`."* AD-23 is the
  *application* of that rule, not a breach of it. The pre-AD-23 text made `FabricReady`
  unsatisfiable (Q1), and an unsatisfiable gate is a gate that gets weakened at build time.
  AD-23 relocated the invariant to the object that can actually satisfy it, documented the
  limitation (R-46), and required `Ready=False/RoutesMissing` on the affected service. That is
  the principle working.
- Principle I's "name the specific missing invariants" is satisfied where the invariant exists:
  `RoutesMissing` is a defined reason on both `Fabric` and `Network`
  (`data-model.md:911`, `:941`), and the `Network` read-back is keyed to its own EVPN instance,
  tunnel and VTEP destinations (`data-model.md:744-770`).
- FR-100's "a fabric-wide or device-wide count is never evidence" is the constitutional
  descendant of the predecessor's disputed record (`spec.md:109`). A fabric-wide EVPN
  received-route count is precisely that kind of evidence. Retaining it would have *reinstated*
  the defect the specification exists to close.
- Principle VI names `fabric_verify` for "BGP, EVPN, and data path". EVPN is still covered:
  T051 reads and reports it, T064 asserts it with a negative control, T167 re-asserts it under
  fault. Coverage moved; it did not shrink.

**Conclusion**: AD-23 **does not weaken Principle VI** — it enforces it. It **marginally weakens
Principle I**, not by removing the route invariant (which was unsatisfiable) but by describing
the replacement as device-state evidence when it is a config echo. That weakening is fully
addressed by amendments A1–A3, which cost no design change.

---

## Q6 — Consistency of the remediation across the feature directory

**The remediation was applied thoroughly.** No surviving statement makes `Fabric` readiness
require an EVPN route count. The only occurrences of the old formulation are in change-log and
rationale rows that correctly describe it as superseded (`spec.md:1777`, `research.md:2361`),
and in G8's description, where "actually exchanged" is correct because G8 runs on scratch
instances (`quickstart.md:145`, `plan.md:637`, `spec.md:734-736`). T041 / T051 / T052 / T064,
`data-model.md` §3a, `contracts/reconciliation.md`, `quickstart.md` §4 and §8, and `plan.md`
P2/P3/SC-004/R-46 agree with each other.

Residual inconsistencies found, in descending severity:

| # | Severity | Location | Finding |
|---|---|---|---|
| R1 | **High** | `evidence/06-telemetry-visualization.md:855-859` | `alert: EvpnRoutesLost` is `network_instance_protocols_bgp_neighbor_afi_safi_received_routes{afi_safi="evpn"} == 0 and on(source) …session_state == 5`, `for: 3m`. That is **exactly** the state AD-23 declares correct. The alert will fire on every leaf and spine from three minutes after `FabricReady` until the first spanning service, and again after every service is deleted. `plan.md:1110` cites this alert as an R-46 mitigation; as written it is a guaranteed false positive in the one window R-46 is about, and `quickstart.md:980` presents it to the operator as covering *"the sessions up, zero routes signature"*. Training an operator to ignore this alert defeats the control. Needs a guard on the presence of at least one `bgp-evpn bgp-instance` |
| R2 | **Medium** | `spec.md:188-189` vs `data-model.md:200-212`, `contracts/reconciliation.md:106-112`, `tasks.md:173` | User Story 1 scenario 2 promises *"routed leaf-spine links and system loopbacks are reachable"*. No `Fabric` read-back reads loopback reachability. The acceptance scenario and the implemented invariant disagree |
| R3 | **Medium** | `quickstart.md:288-292` vs `:301-302`, `tasks.md:173`, `tasks.md:185` | Command (a) reads `session-state` only; the stated expectation and T041/T051 both require the EVPN family negotiated. No command in the quickstart reads it. Exact path in Q3 above |
| R4 | **Medium** | `quickstart.md:402-418` (§8) vs `tasks.md:228` (T064), `plan.md:781-786` (P3 gate) | T064 and P3 both require the route assertion to be *preceded* by its negative control (`inter-as-vpn` removed from one spine as a declared injected fault). §8 of the operator walkthrough — the document that defines the run — never mentions it. `grep -n "negative control\|injected fault" quickstart.md` returns only `:653` and `:1114` |
| R5 | **Low** | `plan.md:1110` (R-46), `plan.md:296`, `data-model.md:200-212` | All three lean on the state-vs-written distinction for `inter-as-vpn`. R-46's *"from the **state** … not from what was written"* is, for a config leaf on SR Linux, a distinction without a difference (Q2b). This is the wording A1 fixes |
| R6 | **Low** | `tasks.md:156` (T027) vs `tasks.md:173` (T041) | `route-reflector client true` on the spine's overlay group is in the render and its golden file, and in no read-back. Same category as `inter-as-vpn` and the same cost to add (A2) |
| R7 | **Informational** | `data-model.md:744-770` (`mac-vrf` row) vs `tasks.md:228`, `spec.md:863-877` | The `mac-vrf` applied-side row proves cross-leaf reachability through VTEP/multicast-destination state, not through an RT2/RT3 route read. The route read lives in T064's shell assertion. Both are keyed and both are legitimate, but FR-100 and the `RoutesMissing` reason speak of "EVPN routes", so a reader may expect the controller itself to read routes. Worth one clarifying clause; not a defect |

---

## Proposed amendments — *proposals only, not applied*

### A1 — Say what the `inter-as-vpn` read-back is (fixes R5, closes the Principle I gap)

In `research.md` AD-23 **Decision** bullet, after *"…and `inter-as-vpn` reported `true` by every
reflecting spine"*, add:

> `inter-as-vpn` and `route-reflector client` are **configuration** leaves; SR Linux's state
> datastore is the running configuration plus operational data, so reading them back with
> `--type state` proves the setting is applied on the device, not that reflection works. They are
> read as a **configuration-integrity** invariant, not as applied-side behavioural evidence. The
> behavioural proof of reflection is G8 on this image, the post-render probe of T051, and the
> first `Network` that spans two leaves.

Mirror the same sentence in `data-model.md:200-212` (§3a, after the `inter-as-vpn` clause) and in
`contracts/reconciliation.md:106-112`.

In `plan.md:1110` (R-46), replace

> *"The `Fabric`'s read-back includes `inter-as-vpn` from the **state** of every reflecting spine,
> not from what was written;"*

with

> "The `Fabric`'s read-back includes `inter-as-vpn` and `route-reflector client` read back from
> every reflecting spine — a configuration-integrity check, not a behavioural one, since both are
> config leaves that the state datastore mirrors; the behavioural proof is G8, T051's post-render
> probe and the first spanning service;"

In `plan.md:296` (Principle I gate), replace *"it reads its sessions and the reflecting spines'
reflection setting"* with *"it reads its interfaces and sessions as true operational state, the
reflecting spines' reflection settings as a configuration-integrity check that is stated as such,"*.

### A2 — Add the two free read-backs (fixes R3, R6, and Q2d #1)

In `tasks.md:173` (T041), replace

> *"every underlay and overlay BGP session established **with the EVPN family negotiated**, and
> **`inter-as-vpn` read back `true` from the state of every reflecting spine**"*

with

> "every underlay and overlay BGP session established (`…/neighbor[peer-address=<ip>]/session-state
> == established`) **with the EVPN family negotiated**
> (`…/neighbor[peer-address=<ip>]/afi-safi[afi-safi-name=srl_nokia-common:evpn]/oper-state == up`,
> a `config false` leaf whose own model description is 'Negotiated operational state of the address
> family is up'), and **`inter-as-vpn` and `route-reflector client` read back `true` from every
> reflecting spine** — a spine that does not report either is `Ready=False` naming that spine and
> the setting"

Mirror the added `route-reflector client` clause in `data-model.md:200-212`,
`contracts/reconciliation.md:106-112` and `plan.md:709-717` (P2 gate).

### A3 — Close the loopback-reachability gap (fixes R2)

Add to the `Fabric` applied side in `data-model.md:200-212` and `tasks.md:173`:

> and, keyed to the loopbacks the `Fabric` itself allocated, every **other** node's `system0.0`
> address present and `active == true` in this node's route table
> (`/network-instance[name=default]/route-table/ipv4-unicast/route[ipv4-prefix=<remote /32>]
> [route-type=bgp][…]/active`, and the `ipv6-unicast` equivalent where the family is enabled) —
> which is what `spec.md` User Story 1 scenario 2 already promises and is genuine applied-side
> evidence that the underlay policy admits what it must (the platform's `ebgp-default-policy`
> defaults reject everything on a policy-less eBGP session).

This is keyed to objects the `Fabric` owns, so it satisfies FR-100; it is not a device-wide count.

### A4 — Give the quickstart the family command (fixes R3)

In `quickstart.md:288-292`, replace block **(a)** with two paths in one `get`:

```bash
# (a) every session established, and the EVPN family negotiated on each overlay session
gnmic -a leaf01:57400 --skip-verify -u "$SRL_USER" -p "$SRL_PASS" -e json_ietf get --type state \
  --path '/network-instance[name=default]/protocols/bgp/neighbor[peer-address=*]/session-state' \
  --path '/network-instance[name=default]/protocols/bgp/neighbor[peer-address=*]/afi-safi[afi-safi-name=srl_nokia-common:evpn]/oper-state'
```

and add to block **(c)** the second spine path
`…/protocols/bgp/group[group-name=<overlay>]/route-reflector/client`. Note in §4 that both (c)
paths are configuration leaves the state datastore mirrors (A1), and that the identityref
qualifier `srl_nokia-common:evpn` is confirmed by G12.

### A5 — Record the scope boundary of the premise (Q1 caveat, Open item 4)

In `research.md` AD-23 **Rationale**, after *"A device originates an EVPN route only for an EVPN
instance"*, add:

> — with one scope-dependent exception: Ethernet Segment (Type 4) and Ethernet A-D per ES
> (Type 1) routes are originated from `/system/network-instance/protocols/evpn/ethernet-segments`,
> which is not inside a `mac-vrf`. EVPN multihoming is out of scope and no ESI is ever claimed,
> so that subtree is empty here; **if multihoming is ever added, this rationale must be re-derived.**

And in `research.md` Open item 4, after *"comes from a vendor engineer's writing rather than from
release documentation"*, add:

> The **mechanism** is now documented: Nokia's VPN Services guide states that `inter-as-vpn true`
> *"allows received EVPN/IP-VPN routes to be retained in the BGP RIB and propagated to any eBGP or
> iBGP peer"*, and the pinned model scopes that to routes *"not imported by any network-instance"*,
> which on a non-VTEP spine is every EVPN route it receives. What remains undocumented is the
> explicit statement that an RR spine requires it; G8 supplies that empirically.

### A6 — The post-render probe, and SC-004 admissibility (closes R-46, fixes R4)

In `tasks.md:185` (T051), add to `fabric_verify.sh`:

> and (d) a **post-render reflection probe** under FR-108, run once per fabric bring-up after every
> fabric `Config` is Applied and before any `Network` exists: a scratch `mac-vrf` with `bgp-evpn`
> on each leaf, the resulting Type-3 route observed *received through the spines* on the other
> leaf, then removed by the same script with the removal read back on every node before the run
> continues — **reported and evidence-captured, never an input to `Fabric.status`** (FR-108
> forbids a fabric outcome depending on verification tooling). This is what proves reflection on
> the **provider-rendered** fabric rather than on the gate's own scratch configuration, and it is
> what R-46 is otherwise left carrying.

In `quickstart.md` §8 (at `:402-418`), add before the expectations:

> `make verify-services` runs its **negative control first**: `inter-as-vpn` is removed from one
> spine as a declared injected fault (FR-108), the spanning service must report
> `Ready=False/RoutesMissing` naming its routes, and the revertive policy restores the setting
> before the positive assertion is admitted. A pass that was never shown able to fail is not a pass
> (NFR-013).

In `plan.md:969` (SC-004 row), add a closing sentence:

> `FabricReady` on its own is **never** SC-004 evidence; the acceptance script refuses to record
> SC-004 until both observations, and the route half's negative control, are present in the
> evidence directory.

### A7 — Fix the alert (fixes R1)

In `evidence/06-telemetry-visualization.md:855-859`, guard `EvpnRoutesLost` so it cannot fire on a
fabric that carries no EVPN instance — e.g. add
`and on(source) (count by (source) (network_instance_protocols_bgp_evpn_bgp_instance_oper_state == 1) > 0)`
(exact series name to be confirmed against the collector's generated naming, which is itself a
G7/G12-adjacent observation), and note in `quickstart.md:980` that the alert is silent by design
on a service-less fabric. As it stands the alert contradicts AD-23 and `plan.md:1110` relies on it.

---

## What remains UNVERIFIED, and which capability-gate item should observe it

| # | Unverified claim | Why it is unverified | Gate item that should observe it |
|---|---|---|---|
| U1 | That omitting `inter-as-vpn` on a non-VTEP RR spine actually produces "sessions established, zero EVPN routes" **on this image** | Derived from the model's own text and a vendor engineer's blog; Nokia release documentation states the command's function but never states the RR requirement (fetched 2026-09-20). Research Open item 4 | **G8** — already carries it, with its negative control at `tasks.md:178` (T045). No change needed beyond A5's wording |
| U2 | That `--type state` returns a config-only leaf such as `inter-as-vpn` and `route-reflector/client` at all (as opposed to requiring `--type config` or `all`) | Inferred from Nokia's datastore definition; not observed on the pinned image. If it does **not**, `quickstart.md:297-299` and T041 are broken as written | **G4** (Set, read-back, durable persistence) — extend its read-back to include one config-only leaf read via `--type state` |
| U3 | The JSON_IETF serialization of the `afi-safi-name` key — `srl_nokia-common:evpn` vs bare `evpn` vs a prefix form — in both the request path and the response | Module-name qualification is the RFC 7951 rule and the identity is in `srl_nokia-common`, but the device's actual echo is unobserved. Every path in Q2a/Q3 and in `quickstart.md:291`, `:299` depends on it | **G12** — already the item for exactly this; add the two `afi-safi` paths to its observed set before goldens freeze |
| U4 | That `…/neighbor[…]/afi-safi[…]/oper-state` is populated (not absent) on an established iBGP EVPN session on the containerized `nokia_srlinux` node type | Model-verified; emulation behaviour unobserved | **G8**, or **G7** if read via Subscribe |
| U5 | That `received-routes`/`sent-routes` on the spine's per-neighbour EVPN family read `0` on a service-less fabric and non-zero after the first spanning service — the counter the `EvpnRoutesLost` alert and `quickstart.md` §4 block (b) both rest on | Unobserved | **G8** (it already exercises both states) |
| U6 | The effect of the platform's `ebgp-default-policy` defaults in the rendered underlay, i.e. whether every node's `system0.0` /32 is actually installed and `active` on every other node | Model defaults verified (`:3947-3962`); the rendered policy's sufficiency is unobserved. A3 turns this into a standing invariant | **G8** (it needs a working underlay anyway) — record the loopback route read as a captured sub-step |
| U7 | Whether the `EvpnRoutesLost` guard series proposed in A7 exists under that name in the collector's generated metric naming | The metric naming is generated from gNMI paths and is itself listed at `plan.md:645-648` as something to qualify alongside the gate | **G7** (Subscribe) plus the OTLP/collector shape qualification named at `plan.md:645-648` |

---

## One-line summary for the operator

AD-23's premise is correct and the canary is rightly rejected — but the invariant that replaced
the route count is a configuration read-back wearing device-state clothing. Ratify the decision,
change six sentences so it says what it is, add three checks that cost one `Get` each, run G8's
proof a second time against the fabric the provider actually rendered, and fix the alert that
fires throughout the window this decision declares healthy.

---

## Applied 2026-09-20

The operator ratified AD-23 with amendments A1–A7. The amendments and residuals R1–R7 were applied
to the design artefacts as **AD-31**. Every edit was made with the locked atomic editor; no
checkbox was ticked, no identifier was renumbered, and no new FR/NFR/SC/R/T/G identifier was added.

| File | Anchor text edited | What was applied |
|---|---|---|
| `research.md` | AD-23 **Decision**, `"…reported \`true\` by every reflecting spine. It never counts EVPN routes."` | A1 — the configuration-integrity paragraph |
| `research.md` | AD-23 **Rationale**, `"A device originates an EVPN route only for an EVPN instance"` | A5 — the ethernet-segment scope boundary |
| `research.md` | AD-23 **Alternative rejected**, after `"R-46 records what is given up."` | new "Also rejected" bullet: a probe that gates readiness is forbidden by FR-108 |
| `research.md` | AD-23 **Consequences** | "Ratified with amendments … the amendments are `AD-31`" |
| `research.md` | `### AD-31: [[STUB-AD-31]]` | the full AD-31 entry (Decision / Rationale / Alternatives rejected / Consequences), recorded as an operator decision citing this report |
| `research.md` | Open item 4, `"rather than from release documentation."` | A5 — the model text and Nokia VPN Services guide wording; U1/U2/U4/U5 named as G8 observations |
| `data-model.md` | §3a, `"\`Ready=True\` requires every node's fabric \`Config\` applied at priority 10"` | A1 + A2 + A3 — family `oper-state` path, loopback route-table check, `route-reflector client`, configuration-integrity wording |
| `contracts/reconciliation.md` | Rule 5, `"The \`Fabric\`'s applied side is its own objects, and never a route count"` | A1 + A2 + A3, and the probe named as non-gating under FR-108 |
| `plan.md` | intro, `"This plan now carries **\`Fabric\` readiness without a route count**"` | A1 + A2 + A3 summary |
| `plan.md` | C-05 component row, `"the \`Fabric\`'s applied side being its own sessions…"` | A1 + A2 + A3 |
| `plan.md` | Principle I gate row, `"it reads its sessions and the reflecting spines' reflection setting"` | A1 — separates true operational state from the configuration-integrity read |
| `plan.md` | P2 gate, `"Gate: the underlay and overlay sessions establish with the EVPN family negotiated"` | A1 + A2 + A3 + A6 |
| `plan.md` | P0 gate rows **G4**, **G7**, **G8**, **G12** | U1–U7 lodged in the existing gate items |
| `plan.md` | SC-004 row | A6 — `FabricReady` alone is never SC-004 evidence |
| `plan.md` | R-46 row | A1 + A6 + A7 — rewritten mitigation, `AD-23, AD-31` |
| `spec.md` | User Story 1 scenario 2 | A2 + A3 + A1 |
| `spec.md` | FR-100, `"The fabric design's own readiness follows the same rule"` | A1 + A2 + A3, with the configuration-integrity statement made a MUST |
| `spec.md` | SC-004 | A6 admissibility |
| `spec.md` | edge case, `"Caught three times over"` → four | the post-render probe added as a catch |
| `spec.md` | fourth-pass remediation row for User Story 1 / FR-100 / SC-004 | records the operator ratification and AD-31 |
| `tasks.md` | **T041** applied-side clause | A1 + A2 + A3 |
| `tasks.md` | **T043** G4, G8 and G12 clauses | U1–U6 |
| `tasks.md` | **T051** `fabric_verify.sh` | A1 + A2 + A3 and **A6's post-render reflection probe** as step (d) |
| `tasks.md` | **T052** evidence capture clause | A6 admissibility |
| `tasks.md` | **T130** alert-rule list | A7 — the guarded `EvpnRoutesLost` requirement |
| `quickstart.md` | §4 command block (a)/(a2)/(c) and the expected paragraph | A4 + A2 + A3 + A1, and the probe named |
| `quickstart.md` | §8, before `"Expected: bridged and routed network instances"` | R4 — the mandatory negative control stated in the walkthrough |
| `quickstart.md` | §21, `"\`EvpnRoutesLost\` covers the \"sessions up, zero routes\" signature"` | A7 |
| `quickstart.md` | `FabricReady` phase row; gate rows **G4**, **G7**, **G8**, **G12**; the diagnosis-table row | A2/A3 and U1–U7 |
| `evidence/06-telemetry-visualization.md` | above `- alert: EvpnRoutesLost` | dated **"Superseded 2026-09-20 by AD-31"** note; the draft rule itself left untouched (research report, not a design artefact) |
| `traceability.md` | after the AD-30 row; the R-46 row | AD-31 recorded; R-46 amended |

**Not applied, and why**: the `AD-01…AD-30` range strings in `plan.md`, `tasks.md` and `spec.md`
were left alone — every concurrent agent shares them, and a range bump belongs to one hand. No new
spec section was opened for the operator review for the same reason; the fourth-pass row was
amended in place instead. `evidence/06`'s alert expression was annotated, not rewritten.
