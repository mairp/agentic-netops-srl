# 03 — The SR Linux ACL model, and the rewritten access-list render + verification contract

**Topic owner**: replaces PC-06, PC-07, PC-08, PC-09, PC-10, PC-12, PC-13, PC-A-02.
**Answers**: `spec.md` §Open decisions 4. **Touches**: US5, FR-035..FR-043, SC-014, SC-015,
GAP-4, GAP-6, the three ACL Assumptions, D-12..D-16, R-25, R-26.
**Date**: 2026-09-20.

---

## 0. Release pinned by this report, and why

**Recommended pin: SR Linux `25.7.1` — image `ghcr.io/nokia/srlinux:25.7.1`, YANG
`github.com/nokia/srlinux-yang-models` tag `v25.7.1`, sdcio schema `srl.nokia.sdcio.dev-25.7.1`.**

Every path, pattern, range, enum and `must` in this document was read out of
`srl_nokia/models/acl/srl_nokia-acl.yang` and `srl_nokia/models/acl/srl_nokia-packet-match-types.yang`
at **tag `v25.7.1`** unless a line explicitly says otherwise.
[VERIFIED: local clone `/tmp/.../scratchpad/srl-v25.7.1/srlinux-yang-models/srl_nokia/models/acl/`,
`git clone -b v25.7.1 --depth 1 https://github.com/nokia/srlinux-yang-models`]

Why 25.7.1 and not something newer or older (toolchain evidence gathered this session):

| Constraint | Finding |
|---|---|
| sdcio schema build | sdcio ships no prebuilt schema store; a `Schema` CR builds from `nokia/srlinux-yang-models@vX.Y.Z` **plus** `sdcio/srlinux-yang-patch@vX.Y` (deviations). The deviations branches that exist are `v24.7`, `v24.10`, `v25.3`, `v25.7` — **25.7 is the ceiling** [VERIFIED: https://api.github.com/repos/sdcio/srlinux-yang-patch/branches] |
| sdcio CI | runs end-to-end against `ghcr.io/nokia/srlinux:25.7.1` with `schema-nokia-srl-25.7.1.yaml` [VERIFIED: https://github.com/sdcio/integration-tests/blob/main/containerlab/citest.clab.yml, https://github.com/sdcio/integration-tests/blob/main/tests/01-crs/schema/schema-nokia-srl-25.7.1.yaml] |
| containerlab | imposes no SR Linux version ceiling; kind `nokia_srlinux`, default `type: ixr-d2l` [VERIFIED: `clab-src/nodes/srl/srl.go:34` `SRLinuxDefaultType = "ixr-d2l"`, containerlab `v0.79.0` installed locally] |
| kubenet | frozen on `ghcr.io/nokia/srlinux:24.3.2-118` + schema `srl.nokia.sdcio.dev-24.3.2`; repo unchanged since 2024-11-18 [VERIFIED: https://github.com/kubenet-dev/kubenet/blob/main/lab/3node.yaml, .../sdc/schemas/srl24-3-2.yaml] |

kubenet is a *stale* pin rather than a technical ceiling — it consumes sdcio `Schema` CRs, so moving
it to 25.7.1 is one new CR plus an image bump. If the project instead wants zero modification to
kubenet examples, the fallback is **24.3.2**; everything in this document also holds at 24.3.2
because the ACL restructure landed *in* 24.3.1 (below), with the two exceptions flagged inline
(the egress `subinterface-specific` must, and the `choice port`/`ttl`/`hop-limit` additions).

### The 24.3 restructure — confirmed, and only the new form is specified here

| Release | Filter object | Binding point |
|---|---|---|
| ≤ 23.10 | `/acl/ipv4-filter[name]`, `/acl/ipv6-filter[name]` (two separate lists) | under the filter, a `subinterface` list |
| ≥ 24.3.1 | `/acl/acl-filter[name][type]`, `type ∈ {ipv4, ipv6, mac}` | `/acl/interface[interface-id]` with `input`/`output` `acl-filter[name][type]` |

[VERIFIED: `v23.10.8` `srl_nokia-acl.yang` lines 1491/1576 = `list ipv4-filter` / `list ipv6-filter`;
`v24.3.3` lines 1365/1500 = `list interface` / `list acl-filter`. The 25.7.1 module carries the
in-source comment `uses acl-filter-top; //24.3 Openconfig Related Changes`.]

**Only the ≥24.3 form appears anywhere in this document.** Note that the local doc mirror
`/root/learn-srlinux/docs/cli/show-commands/acl.md` still shows the *old* `show acl ipv4-filter ip_tcp`
form — it is pre-24.3 and must not be used as a source for the retarget
[VERIFIED: /root/learn-srlinux/docs/cli/show-commands/acl.md:36].

---

## 1. Filter identity — PC-06 is deleted, a sanitiser survives

### The facts

```
list acl-filter {
  key "name type";
  leaf name { type srl_nokia-comm:name;
              must "not (. = 'system')" { if-feature "not srl_nokia-feat:system-filter"; } }
  leaf type { type enumeration { enum ipv4 {value 1} enum ipv6 {value 2} enum mac {value 3} }
              must "not (../name = 'system' or ../name = 'capture') or . = 'ipv4' or . = 'ipv6'"; }
```
[VERIFIED: v25.7.1 `srl_nokia-acl.yang` lines 1913–1946]

`srl_nokia-comm:name` resolves to:

```
typedef name        { type alphanumeric { length "1..255"; } }
typedef alphanumeric{ type string {
   pattern '[A-Za-z0-9!@#$%^&()|+=`~.,/_:;?-][A-Za-z0-9 !@#$%^&()|+=`~.,/_:;?-]*'; } }
```
[VERIFIED: v25.3.3 `srl_nokia/models/common/srl_nokia-common.yang` lines 1167–1189; identical typedef in v25.7.1]

So, versus SONiC's `[a-zA-Z0-9]{1}([-a-zA-Z0-9_]{1,63})`:

| Property | SONiC (PC-06) | SR Linux 25.7.1 |
|---|---|---|
| Length | 2–64 | **1–255** |
| First char | alphanumeric only | alphanumeric **or** any of `!@#$%^&()|+=\`~.,/_:;?-` (a leading **space** is the only thing excluded) |
| Dot | forbidden | **allowed** |
| Hyphen / underscore | allowed | allowed |
| Space | forbidden | **allowed, except as the first character** |
| Reserved names | none | `system`, `capture` are reserved and refused by `must` (`capture` for packet-capture filters, `system` for system filters) [VERIFIED: v25.7.1 lines 1918–1946 and acl-25-3 guide §"Packet capture filters"/"System filters"] |

### Recommendation

**Delete PC-06's *derivation function*. Keep only a sanitiser plus a reserved-name refusal.**

The derivation function existed because "a device once rejected a 19-character generated name"
(PC-06 note). SR Linux's 1–255 window and near-open alphabet means a generated service identifier
and an operator label both fit by construction; there is nothing left to derive around.

What must still exist, and it is small:

1. **A sanitiser**, not a deriver: reject a leading space, reject any character outside the
   `alphanumeric` pattern, reject length 0 or >255. Refuse at validation time naming the offending
   character — do not silently rewrite, because a silently-rewritten name breaks the
   apply/verify/rollback name agreement that D-13's rationale was actually about.
2. **A reserved-name refusal**: `system` and `capture` are refused by name, with the reason stated
   ("reserved for system filters / packet-capture filters on this platform"). This is a *new*
   refusal the SONiC contract did not have, and the device enforces it — so the refusal is a
   necessity, not a policy choice.
3. **Determinism still required.** Keep D-13's "apply, verify and rollback derive the same name"
   property. The recommended name is `<tenant>-<serviceId>-<stage>` or similar, but it is now a
   *choice about readability*, not a workaround for a hostile alphabet.

### Requirement wording consequence

- PC-06 row is **deleted** from `platform-coupling.md` and replaced by a much smaller
  platform-specific row: "`srl_nokia-comm:name`'s 1–255 alphanumeric-plus-punctuation pattern and
  the reserved names `system` and `capture`".
- `acl-render-contract.md` §2's sentence *"matching the YANG's name rule (2–64 characters, first
  character alphanumeric, no dot, no space): sanitize to the YANG alphabet, cap the derived
  remainder, prefix with an alphanumeric"* is rewritten to *"sanitize to the YANG alphabet
  (1–255 characters, first character not a space); refuse rather than rewrite; the names `system`
  and `capture` are refused as reserved"*.
- **The filter key is a pair, not a scalar.** `key "name type"` — every render, verify, rollback
  and gNMI path in the whole contract carries `[name=…][type=…]`. This is a structural change to
  every check entry and is the single most mechanical edit in the retarget.

---

## 2. Filter types — the MAC refusal survives, but its *reason* changes

### The facts

`type` is `ipv4 | ipv6 | mac`. `mac` is gated:

```
enum mac {
  if-feature "srl_nokia-feat:platform-7215-a1 or platform-7220-d2 or platform-7220-d3
              or platform-7220-d4 or platform-7220-d5 or wolfhound3p";
  value 3; }
```
[VERIFIED: v25.7.1 `srl_nokia-acl.yang` lines 1938–1941. In v25.3.3 the last disjunct is
`srl_nokia-feat:future-0-0` instead of `wolfhound3p` — cosmetic.]

A MAC filter *is* a real interface filter on the 7220 IXR-D family: it applies to routed or bridged
subinterfaces, input or output, and matches `destination-mac`, `source-mac`, `ethertype`, and
`vlan/outermost-vlan-id` [VERIFIED: acl-25-3 guide §"MAC interface filters"; YANG grouping
`common-acl-filter-entry-match-l2-config`, v25.3.3 lines 497–634].

Three hard device facts about MAC filters that matter for the refusal wording:

1. **MAC and IP filters are mutually exclusive per subinterface per direction.** *"For a specific
   direction of traffic (input or output), a routed or bridged subinterface of an Ethernet port or
   LAG can have either a MAC interface ACL or an IPv4/IPv6 interface ACL applied, but not both at
   the same time."* [VERIFIED: acl-25-3 guide §"MAC interface filters"]
2. **MAC ACLs are not supported on IRB subinterfaces, loopback, or `system0`.** [VERIFIED: same section]
3. **An egress MAC filter requires a global switch**: `set / acl egress-mac-filtering true`, which
   silently caps egress IPv4/IPv6/MAC ACL instances at 32 each [VERIFIED: v25.7.1 lines 2014+,
   `leaf egress-mac-filtering`, and acl-25-3 guide §"Attach a MAC ACL to a subinterface"].

### Recommendation

**Keep the L2/MAC refusal. Change its justification from "the device has no such type" to
"the composite's declared scope is L3".**

The spec's own Assumption — *"Access-list scope is the match and action set the cited reference
documents — stage, address family, prefixes, IP protocol, L4 ports, permit and deny"* — is
already the load-bearing constraint, and it is platform-neutral. Item 1 above is the decisive
engineering reason: admitting `mac` would make the unit of exclusivity **(subinterface, direction)**
rather than **(subinterface, direction, address family)**, because a MAC filter and an IP filter
*cannot coexist* on the same subinterface and direction. That would force a strictly more
restrictive conflict rule for every service, including the ones that never asked for MAC.

Word the refusal so it is honest about which kind of "no" it is:

> A MAC (Layer 2) access list is out of scope for this platform. SR Linux does provide an
> `acl-filter` of `type mac`, but this system's access-list construct is defined over address
> families — the accepted types are `ipv4` and `ipv6`. Admitting `mac` would also change the unit
> of binding exclusivity, because SR Linux forbids a MAC filter and an IP filter on the same
> subinterface in the same direction.

**Do not** reuse the SONiC wording *"the table-type enum has only the mirror and the two L3 types —
there is no L2/MAC table"*. That sentence becomes false on SR Linux and would be a spec-level
factual error.

### Requirement wording consequence

- PC-07 is **rewritten, not deleted**: the coupling is no longer "the enum lacks MAC" but
  "the enum *has* MAC and the composite declines it, and SR Linux's MAC/IP mutual exclusion per
  subinterface-direction is why that decline is also a simplification".
- `acl-render-contract.md` §3 row "an L2 or MAC table type" gets the new reason text above.
- Add a forward note: admitting `mac` later is a **requirement-level** change to FR-038 and FR-043
  (exclusivity unit), not an implementation change.

---

## 3. Entries: sequence-id, ordering, priority mapping, and the reserved terminal slot (replaces PC-09)

### The facts

```
list entry {
  key "sequence-id";
  leaf sequence-id {
    type uint32 { range "0..65535"; }
    description "A number to indicate the relative evaluation order of the different entries;
                 lower numbered entries are evaluated before higher numbered entries"; }
```
[VERIFIED: v25.7.1 `srl_nokia-acl.yang` lines 1699–1710; identical in v25.3.3 lines 1523–1532]

**Evaluation order and the implicit default — the decisive quote:**

> *"If a packet matches an ACL entry, no further evaluation is done for the packet. If the packet
> does not match any ACL entry, **the default action is accept**. To drop traffic that does not
> match any ACL entry, you can optionally configure an entry with the **highest sequence ID** in
> the ACL to drop all traffic. This causes traffic that does not match any of the lower-sequence
> ACL entries to be dropped."*

[VERIFIED: https://documentation.nokia.com/srlinux/25-3/books/acl-policy-based-routing/access-control-lists.html
§"ACL actions"]

And Nokia's own worked example uses exactly `entry 65535` with a bare `drop` and no match fields
[VERIFIED: same page, §"Drop all matching traffic": `acl-filter ip_tcp type ipv4 { entry 65535 {
action { log true drop { } } } }`].

### The direction inversion — state it explicitly, because it is a correctness trap

| | SONiC | SR Linux 25.7.1 |
|---|---|---|
| Ordering leaf | `PRIORITY` | `sequence-id` |
| Which wins | **higher** number evaluated first | **lower** number evaluated first |
| Range | 2–65535 usable; **1 reserved** | 0–65535, all usable |
| Reserved slot for the default | the **lowest** (1) | the **highest** (65535 by convention, not by YANG) |
| Unmatched traffic | table default action | **implicit accept** |

The operator's `priority` in the construct vocabulary is a **relative ordering token**, and its
SONiC semantics were "higher number wins". SR Linux is the opposite. Two mappings are possible:

- **(A) Invert:** `sequence-id = 65534 - rank(priority)` where rank orders the operator's
  priorities descending. Preserves the operator's mental model ("higher priority wins") across the
  retarget, at the cost of a non-obvious device-side number.
- **(B) Rebase (recommended):** stop calling it priority in the operator-facing sense of
  "bigger wins". Sort the operator's rules by their declared `priority` **ascending** and assign
  `sequence-id` by **dense rank × a stride**, i.e. `sequence-id = 10 × rank`, rank starting at 1.
  Lower operator priority number = evaluated first = lower sequence-id. This is order-preserving,
  gap-leaving (a later insert does not renumber), and it makes the device number readable next to
  the operator's intent.

**Recommendation: (B), with the mapping stated in the spec and in the refusal text.**
(A) preserves a SONiC-ism that nothing else in the retarget preserves, and the retarget is already
rewriting FR-039's wording. What must **not** happen is either mapping being left implicit: the
whole point of FR-040's duplicate-priority refusal is that "which of a permit and a deny wins must
never be decided arbitrarily", and a silent direction flip decides it arbitrarily and invisibly.

### The reserved slot and FR-041

- **Reserved sequence-id: `65535`.** Usable range for operator rules: **`0..65534`**.
- With stride 10 and dense rank starting at 1, the practical operator-usable band is `10..65530`,
  i.e. up to 6553 rules — far past any lab need, and `65535` is never reachable by the mapping.
- Nothing in the YANG reserves 65535; it is `uint32 {range 0..65535}` end to end. The reservation is
  **this system's convention, matching Nokia's own documented idiom**, and the spec must say so —
  "the platform's reserved priority" is now a statement about the render contract, not about the
  device model. FR-039's PC-N-05 phrasing ("the lowest priority the platform allows is reserved for
  the default action") is **factually wrong on SR Linux and must be rewritten to "the highest
  sequence-id the platform allows"**.

**FR-041 maps cleanly and gains force.** SR Linux's implicit default is **accept**. So:

- If the operator declares `defaultAction: deny`, the render **must** emit
  `entry 65535 { action { drop { } } }` with no match fields, or the device will silently permit
  everything the rules did not name — the exact "unmatched behaviour is an implication rather than
  a row" failure FR-041 exists to prevent.
- If the operator declares `defaultAction: permit`, the render **should still emit**
  `entry 65535 { action { accept { } } }`, even though it is behaviourally identical to the
  implicit default. Reason: FR-041 says "rendered explicitly rather than left implied", and the
  read-back in §7 then has a row to assert. An accept-with-no-match terminal entry costs one TCAM
  entry and makes the two-sided check symmetric across both default actions.
- **New refusal** (device-enforced, so it is a necessity): an operator rule that maps to
  sequence-id 65535 is refused, stating that 0–65534 is usable and 65535 carries the default action.

### Requirement wording consequence

- PC-09 is replaced by: "`sequence-id` `uint32 {range 0..65535}`, ascending evaluation, first match
  wins, implicit default **accept**; this contract reserves 65535 for the terminal default-action
  entry and maps operator priority ascending to sequence-id by dense rank × 10."
- FR-039: *"The lowest priority the platform allows is reserved for the default action"* →
  *"The platform's terminal evaluation slot — the highest sequence-id — is reserved for the default
  action and is not available to a rule."*
- FR-041: add *"...because the platform's own behaviour for unmatched traffic is to accept it, an
  undeclared or unrendered default is a silent permit"*. This is a **strengthening** of FR-041's
  rationale, and it should be recorded as such.

---

## 4. Match fields and actions — PC-08's ICMPv6 refusal vanishes entirely

### Protocol / next-header

Both `match/ipv4/protocol` and `match/ipv6/next-header` are typed
`srl_nokia-pkt-match-types:ip-protocol-type`, which is:

```
typedef ip-protocol-type {
  type union {
    type uint8 { range "0..255"; }
    type enumeration { ipv6-hop=0, icmp=1, igmp=2, ggp=3, ipv4=4, st=5, tcp=6, egp=8, igp=9,
      udp=17, ipv6=41, idrp=45, rsvp=46, gre=47, esp=50, ah=51, icmp6=58, no-next-hdr=59,
      ipv6-dest-opts=60, eigrp=88, ospf=89, pim=103, vrrp=112, l2tp=115, sctp=132,
      mpls-in-ip=137, rohc=142 } } }
```
[VERIFIED: v25.7.1 `srl_nokia-packet-match-types.yang` lines 170–355; `icmp6 = 58` at line 278]

**The full 0–255 numeric space is expressible, and `icmp6`/58 is a first-class enum.**

> **PC-08 is deleted outright.** The ICMPv6 refusal has no basis on SR Linux. `match ipv6
> next-header icmp6` (or `58`) is valid, and `match ipv6 icmp6 type <t> code [<c>…]` is gated by a
> `must` requiring exactly `next-header = 58 or icmp6`
> [VERIFIED: v25.3.3 lines 1095–1124]. D-15's correction #2 must be **reverted** for this platform
> and the reversion recorded, so a later reader does not reinstate a refusal that was a property of
> a different device.

Note the IPv4 side is symmetric: `match ipv4 icmp type/code` is gated by
`must "string(../../protocol) = '1' or string(../../protocol) = 'icmp'"`
[VERIFIED: v25.3.3 lines 926–954].

### Prefixes

Per address family, under `match/ipv4/` and `match/ipv6/`, both `source-ip` and `destination-ip`
containers offer three mutually exclusive forms:

| Leaf | Type | Note |
|---|---|---|
| `prefix` | `srl_nokia-comm:ipv4-prefix` / `ipv6-prefix` | **use this one** |
| `address` + `mask` | address + **inverse** mask (e.g. `10.10.10.0` + `0.0.0.255` ≡ `10.10.10.0/24`) | mutually exclusive with `prefix` by `must` |
| `prefix-list[name]` | leafref into `/acl/match-list/ipv4-prefix-list[name]`, `max-elements 1`, `if-feature acl-ip-prefix-list` | out of scope — it is a second named object with its own lifecycle |

[VERIFIED: v25.3.3 lines 831–1025 (ipv4) and 1027–1186 (ipv6); acl-25-3 guide §"Match based on
IPv4 address and mask"]

**Wrong-address-family is device-enforced.** Every leaf under `match/ipv4/` carries
`must "string(../../../../type) = 'ipv4'"` (and mutatis mutandis for ipv6)
[VERIFIED: v25.3.3, every leaf in both groupings]. So FR-040's "a prefix in the wrong address
family for the list" refusal is **a necessity on SR Linux, not a policy** — the device rejects the
transaction. Keep the pre-submission refusal anyway (SC-015 requires refusal *before anything is
created on the fabric*), but record that the device is the backstop.

### L4 ports

Under `match/transport/`, `source-port` and `destination-port` each offer:

| Form | Paths | Notes |
|---|---|---|
| single value | `…/operator` (`le\|ge\|eq`) + `…/value` | `operator` has `must "string(../value) != ''"` |
| range | `…/range/start`, `…/range/end` | `must` that `operator` and `value` are both empty |

In 25.7.1 (and 25.10) these are wrapped in `choice port { case value {…} case range {…} }`; in
25.3.3 they are flat siblings guarded by mutual-exclusion `must`s. **A YANG `choice`/`case` does not
appear in the data tree, so the gNMI paths are identical in both releases** — only the enforcement
mechanism changed. [VERIFIED: v25.7.1 lines 650–690 vs v25.3.3 lines 635–730]

`operator` enum:
```
typedef operator { enumeration { le = 1; ge = 2; eq = 3; } }
```
[VERIFIED: v25.7.1 `srl_nokia-packet-match-types.yang` lines 36–60]

Port value type is `l4-port-type`: a union of `uint16 {range 0..65535}` and a large well-known-name
enumeration (`acap=674`, `afp-tcp=548`, …). **Render numbers, never names** — the enum set is
release-dependent and a name is not a stable contract.
[VERIFIED: v25.7.1 `srl_nokia-packet-match-types.yang` lines 357+]

**The "L4 port on a protocol that has none" refusal is device-enforced:**

```
must "string(../../../ipv4/protocol) = '6' or string(../../../ipv6/next-header) = '6'
   or string(../../../ipv4/protocol) = '17' or string(../../../ipv6/next-header) = '17'
   or ... = 'tcp' or ... = 'udp'"
  { error-message "The protocol or next-header must be TCP or UDP to use port value"; }
```
[VERIFIED: v25.3.3 lines 658–672 and every port leaf; unchanged in v25.7.1]

So FR-040's L4-port clause, like the address-family clause, becomes a necessity. **Note the device
is stricter than SONiC**: SCTP (132) has ports but SR Linux's `must` only admits 6 and 17. The
refusal text must say **"TCP or UDP only"**, not "a protocol that has ports".

### Other match fields present but out of scope

`tcp-flags` (pattern `'(\(|\)|&|\||!|ack|rst|syn)+'`, length 1–255, `must` protocol = TCP)
[VERIFIED: v25.3.3 lines 808–826]; `fragment` / `first-fragment` (IPv4 only, `first-fragment`
requires `fragment = true`); `dscp-set` (`if-feature ip-acl-dscp-set`); `ip-option-present`, `ttl`,
`hop-limit` (25.7+ only); `network-instance` (`if-feature acl-cpm-filter-match-network-instance`,
CPM only); the whole `match/l2/` grouping (MAC — §2).

**Recommendation: keep all of these out of scope**, per the spec's Assumption. They are listed here
so a later pass can see what the device offers without re-deriving it. `tcp-flags` is the one most
likely to be asked for and is the cheapest to add (one leaf, one `must` the device enforces).

### Actions

```
container action {
  choice action {
    container accept { presence; ... rate-limit { system-cpu-policer | policer } ... }
    container drop   { presence; must "not (…name = 'capture')"; }
    container copy   { must "…name = 'capture'"; }        # packet-capture only
  }
  leaf log { type boolean; default false;
             must 'not (. = true() and ../../action/accept)'
               { error-message "Logging is not supported with action accept";
                 if-feature "not acl-action-accept-with-log"; } }
}
```
[VERIFIED: v25.3.3 lines 1237–1357]

| Construct action | SR Linux render | Notes |
|---|---|---|
| `permit` | `action accept { }` (a **presence container**, not a leaf value) | |
| `deny` | `action drop { }` (presence container) | *"Dropped IP packets do not result in sending ICMP messages back to the source"* |
| — | `copy` | refused: `must` requires filter name `capture` |
| — | `accept … rate-limit policer/system-cpu-policer` | out of scope (rate limiting) |
| — | `accept … forwarding-class / profile / forward next-hop` | 7730 SXR / QoS only; out of scope |

**`log` — recommend `false`, and refuse `true` rather than offer it.** On the 7220 IXR-D family:

| Filter / direction | `accept + log` | `drop + log` |
|---|---|---|
| IPv4/IPv6 interface filter, **input** | **"No log generated"** | Yes |
| IPv4/IPv6 interface filter, **output** | **"No log generated"** | **"No log generated"** |

[VERIFIED: acl-25-3 guide, Table 3 "Supported actions for each ACL filter type (7220 IXR-D1, D2, and D3)"]

A `log: true` that produces nothing on three of four combinations is exactly the class of silent
overclaim Principle I forbids. Either keep `log` out of the construct entirely (recommended), or
admit it only for `stage: ingress` + `action: deny` and refuse the other three combinations by name.

Note the guide also warns: *"the `drop` action with logging set to `true` is not supported on
7220 IXR-Dx, 7220 IXR-Hx, and 7215 IXS-A1 systems when it is attached as an egress filter"*
[VERIFIED: acl-25-3 guide §"Drop all matching traffic"].

### The rewritten refusal table (replaces `acl-render-contract.md` §3)

| Asked for | Refused because | Device-enforced? |
|---|---|---|
| filter `type: mac` / an L2 access list | out of declared scope (§2); admitting it changes the exclusivity unit | no — device supports it |
| filter named `system` or `capture` | reserved on this platform for system and packet-capture filters | **yes**, `must` |
| `protocol: icmpv6` | **no longer refused** — `next-header icmp6` / `58` is valid | — |
| an L4 port on any protocol other than TCP(6) or UDP(17) | the device's `must` admits only 6/tcp and 17/udp | **yes**, `must` |
| a prefix in the wrong address family for the filter type | every ipv4 match leaf requires `type = 'ipv4'`, and vice versa | **yes**, `must` |
| a rule at the reserved terminal sequence-id (65535) | reserved for the default action; usable range 0–65534 | no — contract convention |
| duplicate sequence-id after mapping / duplicate rule name | evaluation order would be undefined to the operator | list key uniqueness catches the first; the second is ours |
| mirror sessions, policers, `copy`, `forward next-hop`, forwarding-class/profile, rate limiting | out of scope | `copy` yes; rest no |
| binding to a VLAN, a network-instance, or fabric-wide | **see §5** — the binding point is a subinterface | **yes**, structurally |
| `log: true` | no log is generated for accept-input, accept-output or drop-output on this platform | no — silent no-op, which is why we refuse it |
| a prefix-list reference instead of an inline prefix | a second named object with its own lifecycle; out of scope | no |

---

## 5. Binding point — the answer to Open decision 4 (replaces PC-A-02, PC-10, PC-13)

### The facts

```
list interface {
  key "interface-id";  max-elements 16383;
  leaf interface-id { type srl_nokia-comm:name; }              # a free string key
  container interface-ref {
    leaf interface    { leafref -> /interface/name }
    leaf subinterface { leafref -> /interface[name=…]/subinterface/index
        must '../interface';
        must "…/type = 'bridged' or …/type = 'routed' or string(…/type) = ''"
             { error-message "ACL allowed with subinterface type bridged or routed"; }
        must "not(starts-with(../interface,'lo'))"
             { error-message "IP ACLs not allowed on loopback subinterface"; } } }
  container input  { list acl-filter { key "name type"; max-elements 4; ordered-by user; … } }
  container output { if-feature "not platform-7215-a1";
                     list acl-filter { key "name type"; max-elements 4; ordered-by user; … } } }
```
[VERIFIED: v25.7.1 `srl_nokia-acl.yang` lines 1778–1903]

The `input`/`output` `acl-filter` list description, verbatim:

> *"MAC, IPv4, IPv6 ACL filter(s) to be applied on this subinterface direction. **On 7220 and
> 7250 IXR platforms only a single MAC, IPv4 or IPv6 filter is supported.**"*

[VERIFIED: v25.7.1 lines 1826–1829 and 1869–1872]

The guide confirms the reading — *multiple* filters per direction is a **7730 SXR-only** feature:

> *"**7730 SXR** systems allow the following number of interface ACLs to be applied to input or
> output traffic on a subinterface: Input traffic: up to two IPv4 ACLs, up to two IPv6 ACLs.
> Output traffic: one IPv4 ACL, one IPv6 ACL. … When two input ACL filters are applied to a
> subinterface, the order in which the filters are configured determines the filter processing
> order."*

[VERIFIED: acl-25-3 guide §"Attaching an ACL to a subinterface (7730 SXR systems)"]

### Answers to the sub-questions

**How many filters per subinterface per direction?** On the emulated platform (7220 IXR-D2L —
containerlab's default `type`), **one IPv4 filter and one IPv6 filter per direction**, and at most
one MAC filter which is then *mutually exclusive* with the IP filter in that direction (§2). The
`max-elements 4` in the YANG is the model's global ceiling across platforms, not the 7220's limit.

**Does the device itself reject a second filter of the same type?** Two mechanisms, and the answer
is effectively yes, but not for the reason PC-10 gave:

1. The list key is `name type`, so **two filters of the same `type` in the same direction are
   distinct list entries** — the YANG does not reject them structurally.
2. The platform does. Per the YANG description and the guide, only 7730 SXR supports more than one;
   on 7220 IXR the second binding is not supported and the platform-feature machinery rejects it
   at commit. **This is the crucial inversion of PC-10**: PC-10 said "the device gives two lists
   on one port no defined order, so we must refuse". On SR Linux the device *does* define an
   order where it supports the case at all (`ordered-by user`; configuration order = processing
   order, stated explicitly for SXR) — **but on our platform it does not support the case at all**.
   The refusal remains a necessity; its reason moves from *"the order is undefined"* to
   *"the platform accepts only one filter of this type in this direction"*.

**Recommended unit of exclusivity: `(node, base-interface, subinterface-index, direction, filter-type)`.**

That is: **subinterface + direction + address family.** Concretely, `leaf01 / ethernet-1/1 / 100 /
input / ipv4` is the key the pre-flight and the renderer both reason about. It is the finest unit
that is actually exclusive on the device, and it is strictly finer than the SONiC "a port at a
stage" unit — two services may now legitimately share a physical port at the same stage if they
own different subinterfaces, or different address families on the same subinterface.

**Untagged whole port (subinterface 0).** No special case. `ethernet-1/1.0` is a subinterface like
any other; Nokia's own ACL lab binds to exactly this
[VERIFIED: https://github.com/srl-labs/srl-acl-lab `icmp_drop.cfg`:
`/ acl { interface ethernet-1/1.0 { input { acl-filter ICMP_DROP type ipv4 { } } } }`].
The spec must stop saying "port" and say "subinterface"; an operator who names a port with no VLAN
resolves to subinterface 0 through the site inventory, and the exclusivity key is
`(…, ethernet-1/1, 0, input, ipv4)` — which correctly makes an untagged bind and a `vlan 100` bind
on the same physical port **non-conflicting**.

**IRB subinterfaces.** IPv4/IPv6 filters *are* allowed on an IRB subinterface — the `must` admits
`type = 'routed'` and an IRB subinterface is routed. Two caveats to carry:
- **MAC ACLs are not supported on IRB subinterfaces** [VERIFIED: acl-25-3 guide §"MAC interface filters"] — moot given §2.
- Precedence: *"if the IRB also has an input IPv4/IPv6 ACL applied to it, the IRB action takes
  priority over the bridged subinterface MAC ACL action"* [VERIFIED: same section, Table 7].
- The `must "not(starts-with(../interface,'lo'))"` blocks loopback subinterfaces outright.

**Recommendation on IRB**: allow it, but **only when the operator names the IRB explicitly**. Do
not let an `ip-vrf` construct implicitly fan an ACL out onto its IRB subinterfaces — the binding
must be a named subinterface in the request, so that the exclusivity key is knowable at pre-flight.

### The standalone-ACL problem: a subinterface that belongs to another service, or does not exist

This is the real content of Open decision 4 and the spec has nothing on it today. `/acl/interface`
is a **separate top-level list** from `/interface` — an ACL binding is *not* a field inside the
interface object. That is what makes the problem tractable and what makes it dangerous:

- The `interface-ref/subinterface` leafref **requires the subinterface to already exist**. Applying
  an ACL binding to a not-yet-created subinterface fails the leafref at commit.
- But `interface-id` is a **free string key with no leafref and no `must`**, so a binding whose
  `interface-ref` is omitted entirely is structurally valid — Nokia's own lab config omits
  `interface-ref` and relies on the `ethernet-1/1.0` key alone
  [VERIFIED: srl-acl-lab `icmp_drop.cfg`], while the vendor guide sets it explicitly
  [VERIFIED: acl-25-3 guide §"Attach IPv4/IPv6 ACLs to a subinterface"].

**Options for a standalone `acl` bound to named ports:**

| Option | Shape | Consequence |
|---|---|---|
| **O1. Refuse unless the subinterface already exists** | pre-flight resolves each named port+VLAN to an existing `(interface, subinterface)` in observed device state; refuses otherwise, naming the missing subinterface | Honest, SC-015-compliant, no ordering hazard. **Cannot** provision an ACL in the same request that creates the service — but FR-036 already covers that case as a *property of the service*, not a standalone list |
| **O2. Create the subinterface as part of the ACL** | the standalone ACL object owns an interface/subinterface it creates | **Reject.** It makes an access list an interface-provisioning construct, violates the one-owner rule in FR-035, and its rollback would delete a subinterface another service may have come to depend on |
| **O3. Bind by `interface-id` only, omit `interface-ref`** | rely on the free-string key | **Reject.** It is a config that reads back successfully and binds nothing when the name is wrong — the exact class of silent no-op R-26 exists to prevent. The key is unconstrained precisely because it is a label |
| **O4. Defer — write the filter, retry the binding** | apply `acl-filter` immediately, retry `acl/interface` until the subinterface appears | Introduces a partially-converged state the status vocabulary has no word for, and GAP-4's mid-finalization question becomes a mid-*creation* question too |

**Recommendation: O1, with both `interface-id` and `interface-ref` always written.**

- `interface-id` = `"<interface>.<subinterface-index>"` (e.g. `ethernet-1/1.100`) — matching Nokia's
  documented convention so `show`/`info` output is legible.
- `interface-ref { interface <name>; subinterface <index>; }` — **always set explicitly**, so the
  device's leafref is the thing that proves the binding target exists, rather than a string that
  happens to look right.
- The pre-flight resolves the operator's port+VLAN through the site inventory **and** against
  observed device state; a missing subinterface is a refusal naming the subinterface, not a retry.

**Deletion ordering consequence (and a new GAP-4 sibling).** Because `/acl/interface[…]` is a
separate object from `/interface[…]`, a service that deletes its subinterface while an ACL binding
still references it leaves a dangling leafref. The render contract must delete in the order
`acl/interface[…]/input/acl-filter[…]` → `acl/acl-filter[…]` → (only then) anything that owns the
subinterface. Record this explicitly; the SONiC contract had no equivalent because the binding was
a field *inside* the table row.

### Requirement wording consequence

- **PC-A-02 is resolved** and rewritten: "The access-list binding point is a **subinterface**
  (`/acl/interface[interface-id]` + `interface-ref{interface,subinterface}`), and the conflict
  rule's unit of exclusivity is **subinterface + direction + address family**."
- **FR-037** rewritten:
  > **FR-037**: Subinterface binding is the only binding point in scope. An access list MUST be
  > bound to a named base interface and subinterface index in a named direction; it MUST NOT be
  > bindable to a network-instance, a VLAN as such, or fabric-wide, and a request asking for one
  > MUST be refused stating that the list binds to subinterfaces. A request naming a port with no
  > VLAN resolves to subinterface 0. A request naming a subinterface that does not exist on the
  > target node MUST be refused before anything is created, naming the subinterface.
- **FR-043** rewritten:
  > **FR-043**: A request that would bind an access list to a subinterface another service has
  > already bound one to, **in the same direction and for the same address family**, MUST be
  > refused before anything is created, naming the service that holds the binding. The platform
  > itself accepts only one filter of a given type per subinterface per direction, so a second
  > binding is not merely ambiguous but unsupported. An existing binding is never displaced, never
  > merged into, and never joined by a second list.
- **PC-10** rewritten (reason changes from "no defined order" to "one filter per type per direction").
- **PC-13** (`SAI_ACL_BIND_POINT_TYPE_PORT` vs `..._SWITCH`, stock-leaf baseline) is **deleted** —
  there is no SAI object store. Its *purpose* survives in §7.

---

## 6. Egress restrictions, TCAM, and — new — actual dataplane enforcement

### Egress on the emulated platform

The containerlab default is `type: ixr-d2l` = **7220 IXR-D2L**
[VERIFIED: `clab-src/nodes/srl/srl.go:34`; corroborated by `/root/learn-srlinux/docs/get-started/cli.md:136`
showing `Chassis Type : 7220 IXR-D2L` on a containerlab node].

| Question | Answer |
|---|---|
| Egress container present? | Yes. `container output { if-feature "not srl_nokia-feat:platform-7215-a1"; … }` — only the 7215 IXS-A1 lacks it [VERIFIED: v25.7.1 line 1862] |
| Egress IPv4/IPv6 on routed **and** bridged subinterfaces? | Yes — the `interface-ref/subinterface` `must` admits both `routed` and `bridged` for input and output alike [VERIFIED: v25.7.1 lines 1805–1810] |
| A platform-conditional egress constraint? | **Yes, and it is new since 24.3.** From 25.7.1: binding a filter in the `output` direction carries `must "…/subinterface-specific = 'output-only' or … = 'input-and-output'"` under `if-feature "not acl-if-output-shared-tcam-entries"` [VERIFIED: v25.7.1 lines 1886–1891]. Platforms **without** shared output TCAM entries therefore require the filter's own `subinterface-specific` leaf to be `output-only` or `input-and-output` before it can be bound on egress |
| Is that `must` present at 24.3.2? | **No.** It appears in 25.7.1 and 25.10.3 and is absent from 25.3.3 [VERIFIED: diff of the `acl-interfaces-top` grouping between v25.3.3 and v25.10.3] |
| Egress MAC filtering | requires the global `acl egress-mac-filtering true`, which caps egress IPv4/IPv6/MAC instances at 32 each [VERIFIED: v25.7.1 `leaf egress-mac-filtering`] — moot given §2 |
| `drop + log` on egress | *"No log generated"* on 7220 IXR-D [VERIFIED: acl-25-3 guide Table 3] |

**Recommendation for the render contract**: when `stage: egress`, the renderer **must** also emit
`/acl/acl-filter[name][type]/subinterface-specific = output-only` (or `input-and-output` if the
same filter is also bound on ingress). Do this unconditionally rather than feature-detecting: it is
valid on every platform, it is what the 25.7+ `must` demands on the constrained ones, and it has
the side benefit of enabling per-subinterface statistics (§7). Record that it changes the
TCAM-instance accounting — a `subinterface-specific` filter consumes one instance **per
subinterface** rather than one shared instance per linecard
[VERIFIED: v25.7.1 `leaf subinterface-specific` description].

Note the D2L/D3L naming gap: the guide's action tables are titled "7220 IXR-D1, D2, and D3" while
its prose elsewhere enumerates "7220 IXR-D1/D2/D2L/D3/D3L", and the YANG has features
`platform-7220-d2` / `platform-7220-d3` with no separate `-d2l` / `-d3l`
[VERIFIED: v25.3.3 `srl_nokia-features.yang` lines 2782–2790]. **Read D2L as a member of the D2
family and D3L as a member of D3** — this is the guide's own usage
[VERIFIED: acl-25-3 guide §"System filters", §"Rate-limiting action for ACL filters": "7220 IXR-D1/D2/D2L/D3/D3L"].

### TCAM and resource state

Per-entry TCAM cost is exposed **per filter entry**, config false:

```
/acl/acl-filter[name][type]/entry[sequence-id]/tcam-entries/forwarding-complex[complex-identifier]/
    single-instance          # entries needed for one subinterface+direction; non-zero even unapplied
    input-total              # entries used across all subinterfaces applying this filter on INPUT; 0 if none
    output-total             # …on OUTPUT; 0 if none
```
[VERIFIED: v25.3.3 `srl_nokia-acl.yang` lines 96–136, grouping `interface-filter-entry-tcam`]

Global (not per-filter) programming progress:

```
/acl/datapath-programming/forwarding-complex[slot-id][complex-id]/
    programming-complete        # false while entries from prior transactions are still pending
    last-completed-timestamp
```
[VERIFIED: v25.3.3 lines 382–418, grouping `datapath-programming`]

Platform-level resource accounting (the `system resource-management` analogue):

```
/platform/linecard[slot]/forwarding-complex[id]/acl/resource[name]/{used,free}
    # names: input-ipv4-filter-instances, input-ipv6-filter-instances,
    #        if-input-ipv4-stats, if-output-ipv4-stats, …
    #        and on trident3: input-ipv4-filter-instances-routed / -bridged
/platform/linecard[slot]/forwarding-complex[id]/tcam/resource[name]/
    {free-static,free-dynamic,reserved,programmed}
    # names: if-input-ipv4, if-input-ipv6, if-output-ipv4, if-output-ipv6, cpm-capture-ipv4, …
```
[VERIFIED: acl-25-3 guide §"Displaying ACL resource usage" (both `info from state platform linecard 1
forwarding-complex 0 tcam resource if-input-ipv4` and `… acl resource input-ipv4-filter-instances`);
identities in `srl_nokia/models/platform/srl_nokia-platform-acl.yang` lines 86–120 and
`srl_nokia-platform-tcam.yang`]

**These numbers are real in the container**: a containerlab SR Linux node reports
`input-ipv4-filter-instances 0 / 255`, `if-input-ipv4 free-dynamic 18432`, alongside `xdp-*`
datapath resources [VERIFIED: /root/learn-srlinux/docs/cli/show-commands/chassis-and-env.md lines 280–320].

**Recommendation**: do **not** put a TCAM-headroom pre-check in the critical path. At 2–4 rules per
service on a 255-instance / 18432-entry budget it would never fire, and a resource check that never
fires is untested code. Do record the paths here so a future scale test knows where to look.

### Does the containerised dataplane actually enforce ACLs? — **Yes, and this is a capability the SONiC spec did not have**

Three independent pieces of evidence:

1. **The datapath is a real emulated forwarding plane, not a stub.** *"SR Linux XDP — the emulated
   datapath based on DPDK — requires SSSE3 instructions to be available… containerlab will abort
   the lab deployment if it has SR Linux nodes defined"* and this instruction requirement is
   enforced at deploy time [VERIFIED: https://containerlab.dev/manual/kinds/srl/ §"SSSE3 CPU set"].
2. **Nokia's own srl-labs ACL lab is a traffic test.** `srl-labs/srl-acl-lab` on
   `ghcr.io/nokia/srlinux:24.10.1`: ping client→server succeeds; apply an `ICMP_DROP` filter on
   `ethernet-1/1.0` input; *"Repeat the ping, it should not succeed, as the ICMP drop ACL is in
   place. You can check the logs on SR Linux to ensure that the packets are being dropped"*
   [VERIFIED: https://github.com/srl-labs/srl-acl-lab README + `icmp_drop.cfg` + `acl.clab.yml`,
   cloned this session].
3. The container reports non-zero `programmed` TCAM counts and per-entry `matched-packets`
   counters (§7), which a config-only stub would not.

**Recommendation — and it is a requirement-level change, so flag it loudly:**

> The spec's Assumption *"Proving enforcement by passing traffic through a bound port is a different
> class of interaction and is out of scope"* and FR-042's closing clause *"whether the platform
> enforces the filter in its dataplane is neither claimed nor checked"* were written because the
> SONiC virtual switch could not be trusted to forward. **On containerlab SR Linux, enforcement is
> demonstrable and is demonstrated by the vendor's own lab.**

Two ways to take it:

- **(a) Add a third verification tier (recommended, as an independently-gated acceptance test, not
  as a readiness condition).** After `Ready=True`, a test generates traffic from the attached client
  container that the filter should drop and traffic it should permit, and asserts both the outcome
  **and** the per-entry `matched-packets` delta on the right entry. That is a *far* stronger proof
  than any state read, and it closes R-26 by construction: a counter that increments on the entry
  we wrote cannot be another service's entry. Keep it out of the readiness path so that a traffic
  generator failure never makes a correctly-provisioned service report unready.
- **(b) Leave enforcement unclaimed, but delete the sentence that says it *cannot* be claimed** and
  replace it with "not asserted by the readiness path". Keeping "out of scope because it is a
  different class of interaction" would be an *understatement* against observed evidence, which
  Principle I treats the same as an overclaim.

Either way, **SC-014 should gain a clause** and the Assumption must be rewritten. This is the single
biggest capability gain of the retarget in this topic area.

---

## 7. Verification read-back — FR-042 two-sided, scoped so R-26 cannot recur

### "Configuration written" vs "device applied view" on SR Linux, precisely

SONiC had two *stores* (CONFIG_DB db 4, ASIC_DB db 1). SR Linux has **one datastore with two
subtrees**: `config false` nodes are the applied view, `config true` nodes are the intent. The
distinction is made by the **gNMI datastore type**, not by a database number:

| Side | How it is read | What it proves |
|---|---|---|
| **Configuration written** | gNMI `Get` with `type = CONFIG` (gnmic `--type config`) on `/acl/…` | the running configuration contains our filter and our binding — i.e. the transaction committed |
| **Device applied view** | gNMI `Get` with `type = STATE` (gnmic `--type state`) on the `config false` leaves listed below | the filter has been *programmed into the forwarding complex* and *bound to a subinterface* |

**A CONFIG read alone is not convergence**, for the same reason as before: SR Linux validates and
commits configuration that the forwarding complex may still be programming
(`datapath-programming/programming-complete` exists precisely because that gap is real
[VERIFIED: v25.3.3 lines 403–409]).

### The per-filter applied-side evidence (this is what kills R-26)

**`config false` leaves that are non-zero *only* when this specific filter is programmed and bound:**

```
# (1) THE load-bearing one: per-entry TCAM cost, scoped to THIS filter and THIS entry,
#     and split by direction. Reads 0 for the direction the filter is not applied in.
/acl/acl-filter[name=<F>][type=<T>]/entry[sequence-id=<S>]/tcam-entries/
    forwarding-complex[complex-identifier=*]/input-total     # > 0  iff bound on input
    forwarding-complex[complex-identifier=*]/output-total    # > 0  iff bound on output
    forwarding-complex[complex-identifier=*]/single-instance # > 0 even when unbound

# (2) per-entry match counters (require statistics-per-entry = true on the filter)
/acl/acl-filter[name=<F>][type=<T>]/entry[sequence-id=<S>]/statistics/matched-packets
/acl/acl-filter[name=<F>][type=<T>]/entry[sequence-id=<S>]/statistics/last-match
/acl/acl-filter[name=<F>][type=<T>]/entry[sequence-id=<S>]/statistics/incomplete

# (3) the binding, read back from the interface side, with per-entry statistics under it
/acl/interface[interface-id=<IF>.<SI>]/input/acl-filter[name=<F>][type=<T>]/entry[sequence-id=<S>]/
    statistics/matched-packets        # if-feature acl-subinterface-entry-statistics
    statistics/last-match

# (4) global programming progress (a gate, not per-filter evidence)
/acl/datapath-programming/forwarding-complex[slot-id=*][complex-id=*]/programming-complete
/acl/datapath-programming/forwarding-complex[slot-id=*][complex-id=*]/last-completed-timestamp
```
[VERIFIED for (1): v25.3.3 lines 96–136 — *"If the entry is not applied to ingress traffic on any
subinterfaces of this complex then input-total=0"*; (2): lines 1385–1442; (3): lines 1477–1508,
`acl-subinterface-entry-statistics`, sequence-id is a **leafref back into
`/acl/acl-filter[name][type]/entry/sequence-id`**; (4): lines 382–418]

**There is no `oper-state` leaf on an `acl-filter`, and no per-filter "programmed" boolean.**
`tcam-entries/*/input-total` is the closest thing SR Linux has to one, and — unlike anything SONiC
offered — **it is keyed by the filter name, the filter type, the entry sequence-id and the
direction**. Scoping is therefore free; it is impossible to write a switch-wide version of this
check by accident.

### The check set (replaces `acl-render-contract.md` §4)

**Gate (once per node, before the per-filter checks):**

| # | Path | Assert |
|---|---|---|
| G1 | `/acl/datapath-programming/forwarding-complex[*]/programming-complete` | `true` on every complex — no prior ACL transaction is still landing |

**Configuration side (`--type config`), per filter:**

| # | Path | Assert |
|---|---|---|
| C1 | `/acl/acl-filter[name=F][type=T]` | exists |
| C2 | `/acl/acl-filter[name=F][type=T]/entry[sequence-id=S]/action/{accept\|drop}` | the declared action's presence container is present, per rendered rule |
| C3 | `/acl/acl-filter[name=F][type=T]/entry[sequence-id=S]/match/…` | each declared match field equals the rendered value |
| C4 | `/acl/acl-filter[name=F][type=T]/entry[sequence-id=65535]/action/{accept\|drop}` | the terminal default-action entry, always |
| C5 | `/acl/interface[interface-id=IF.SI]/interface-ref/{interface,subinterface}` | equals the resolved base interface and subinterface index |
| C6 | `/acl/interface[interface-id=IF.SI]/<input\|output>/acl-filter[name=F][type=T]` | exists — the binding is present in the declared direction |
| C7 | `/acl/acl-filter[name=F][type=T]/subinterface-specific` | `output-only` or `input-and-output` **when `stage = egress`** (§6) |

**Applied side (`--type state`), per filter — every check carries `[name=F][type=T]`:**

| # | Path | Assert |
|---|---|---|
| A1 | `…/entry[sequence-id=S]/tcam-entries/forwarding-complex[*]/single-instance` | `> 0` on at least one complex, for **every** rendered entry including 65535 — the entry has a TCAM cost, i.e. the entry itself is programmable |
| A2 | `…/entry[sequence-id=S]/tcam-entries/forwarding-complex[*]/input-total` (ingress) **or** `/output-total` (egress) | `> 0` on at least one complex, for **every** rendered entry — **the filter is bound in the declared direction and this entry occupies real TCAM on that path** |
| A3 | `…/entry[sequence-id=S]/tcam-entries/forwarding-complex[*]/<opposite direction>-total` | `== 0` — the filter is **not** bound in the direction the operator did not ask for |
| A4 | `/acl/interface[interface-id=IF.SI]/<dir>/acl-filter[name=F][type=T]/entry[sequence-id=S]` | the leafref-backed per-subinterface entry list is present for every rendered entry — the device's own view of *this filter on this subinterface* |
| A5 | `…/entry[sequence-id=S]/statistics/incomplete` | not `true` — no linecard ran out of statistics resources (only meaningful when `statistics-per-entry` is set) |

**A2 is the clause that closes R-26.** It cannot pass on an unprovisioned node, because there is no
filter named `F` of type `T` to read. It cannot be satisfied by another service's filter, because
the filter name and type are in the path key. It cannot be satisfied by containerlab's stock
`cpm` filter, because that filter is named `cpm`. And it cannot be satisfied by a filter that was
written but never bound, because `input-total` is documented to read 0 in exactly that case.

**Record the SR Linux equivalent of the stock-leaf hazard.** Containerlab writes CPM filter entries
into the factory config of every SR Linux node it starts —
`set / acl acl-filter cpm type ipv4 entry 88 …` (telnet), `entry 358 …` (gRPC 57401), and ipv6
equivalents [VERIFIED: `clab-src/nodes/srl/version_configs/acl.cfg`, `.../grpc.cfg`], on top of the
~38 IPv4 and ~39 IPv6 CPM entries the image ships with
[VERIFIED: /root/learn-srlinux/docs/cli/show-commands/acl.md `show acl summary`]. **A "count all
acl-filters" or "count all entries" check passes on a stock containerlab leaf with roughly eighty
entries and zero operator filters** — the identical defect to PC-13's, with a different stock
object. The check set above is immune because every row is keyed; a future reviewer should treat
any unkeyed ACL check as a defect on sight.

### `statistics-per-entry`

`matched-packets` / `last-match` are only populated when the filter carries
`statistics-per-entry true`; *"If this is set to false no hardware resources are allocated to
collecting statistics for this ACL policy"* [VERIFIED: v25.7.1 lines 1984–1996].

**Recommendation: set `statistics-per-entry true` on every rendered filter.** It costs stats TCAM
(`if-input-ipv4-stats`, 8192 free on the emulated platform) and it is the prerequisite for both the
optional traffic test (§6) and any operator-facing "is this rule being hit" answer. Do **not** make
`matched-packets > 0` a readiness condition — a correctly-programmed filter on a quiet link has
zero matches, and a readiness check that requires traffic is a flake generator. Assert the
counter's **existence and non-`incomplete`-ness** (A5), and assert its **delta** only in the
optional traffic test.

### GAP-6 — two-sided read-back stated only for access lists

The gap gets *easier* to close on SR Linux, and the retarget should close it. `vlan`, `mac-vrf` and
`ip-vrf` all have `config false` subtrees in the same datastore reached by the same
`--type state` Get — there is no second store, no enumeration, no object-identifier matching.
**Recommend promoting the two-sided obligation from FR-042 to a construct-neutral requirement**
(e.g. a new FR under §Constructs, or an amendment to FR-034), and letting FR-042 keep only what is
genuinely ACL-specific: the TCAM-entry evidence and the binding-direction assertion. That converts
GAP-6 from "assumed but unwritten" to "written once and inherited", which is what its Reasoning
says it should have been.

---

## 8. The GCU-poisoning hazard is gone; PC-12, D-12 and R-25 are deleted

### What replaces the raw-store split

On SR Linux there is **no raw configuration store, no CONFIG_DB, no GCU, and no
whole-config-versus-raw-store split**. An ACL is ordinary YANG configuration under `/acl`, written
through the same gNMI `Set` transaction as every other construct, via SDC like everything else.

**The leafref that forced the split does not exist.** D-12's rationale was that SONiC's ACL table
`ports@` is a leafref into the port table, and this fabric's attachment ports are kernel devices
that are not port-table rows. On SR Linux the binding leafrefs
(`interface-ref/interface` → `/interface/name`, `interface-ref/subinterface` →
`/interface[…]/subinterface/index`) point at **objects the fabric itself creates and owns**. There
is nothing unresolvable to route around.

### Commit-time validation, verified

> *"All changes to the state included in a SetRequest message are considered part of a transaction.
> **Either all modifications are applied or changes are rolled back to reflect the original
> state.** For changes to be applied together, they must be in a single SetRequest message."*

> *"gNMI uses its own **private exclusive candidate** that restricts other users or services from
> making simultaneous changes to a configuration. If another exclusive session is already active,
> any attempted gNMI updates fail with an error. The gNMI server uses the private exclusive
> candidate name `gnmirpc-<n>`…"*

> *"…all operations must succeed for the SetResponse to return a success message. If any of the
> operations fail, **the contents of all origins roll back**, and the SetResponse returns an error."*

[VERIFIED: https://documentation.nokia.com/srlinux/25-3/books/system-mgmt/gnmi.html §"SetRequest
message", §"Candidate mode"]

Commit is validated in three stages: YANG syntax, then each application, then the forwarding plane
[VERIFIED: same doc set, config-management chapter].

**Conclusion, stated for the requirement text:**

> A bad ACL transaction fails **its own** `SetRequest` and nothing else. The private exclusive
> candidate `gnmirpc-<n>` is discarded; the running configuration is untouched; no later
> transaction — for an access list or for any other construct — is affected. There is no
> image-wide poisoning mode on this platform.

### What surfaces through gNMI when it fails

- A gRPC error status on the `SetResponse` (no partial `UpdateResult` is honoured — the whole
  transaction rolls back).
- The message text carries the YANG `error-message` of the violated `must` where one applies. The
  ones this contract can actually trigger are worth listing in the spec verbatim, because they are
  the device's own refusal text and the render must never produce them:
  - `"The protocol or next-header must be TCP or UDP to use port value"`
  - `"The acl-filter must be of type ipv4"` / `"… of type ipv6"`
  - `"The acl-filter name must not be system or capture"`
  - `"ACL allowed with subinterface type bridged or routed"`
  - `"IP ACLs not allowed on loopback subinterface"`
  - `"On the current platform, subinterface-specific must be set to output-only or input-and-output for egress filters."`
  [VERIFIED: all six read out of v25.7.1 `srl_nokia-acl.yang`]
- Under SDC the same failure surfaces as a validation/apply error on the `Config` object rather
  than as an opaque exit code, which is what makes the "refuse before submission" checks a
  *defence in depth* rather than the only line of defence.

### Requirement wording consequence

- **PC-12 deleted.** **D-12 deleted** (its entire premise is gone). **R-25 deleted** — with a
  one-line tombstone so a reader does not think it was forgotten.
- `acl-render-contract.md` **§1 "Write path — raw store only" is deleted** and replaced by
  "Write path — the same gNMI transaction as every other construct". The unit test asserting
  "no access-list operation is ever emitted as a whole-config write" is deleted with it.
- **§5 "Rollback"** is rewritten from two `redis-cli del` commands to a gNMI `delete` of
  `/acl/interface[interface-id=IF.SI]/<dir>/acl-filter[name=F][type=T]` **then**
  `/acl/acl-filter[name=F][type=T]` — in that order (§5's dangling-leafref note), and in practice
  as a label-selector rollback of the owning object under FR-065..FR-067, since the whole
  raw-executor escape hatch is gone.
- **PC-11 deleted** (CONFIG_DB/ASIC_DB table names, db numbers, and the `redis-*` check types).
  Its replacement is the path table in §7 and two check types: a keyed `gnmi-get-equals` and a
  keyed `gnmi-get-gt` (for `input-total > 0`).
- The **§Recorded divergence** table's "Access lists" row — *"Forced onto raw redis, because a
  YANG-invalid whole-config write poisons every subsequent GCU write image-wide"* — becomes
  historical, and Open decision 1 loses one of its strongest arguments for keeping an executor
  escape hatch.

---

## 9. Golden exemplar

**Operator intent**: *"permit tcp 443 from 10.0.0.0/24, deny everything else, ingress, ipv4, on
leaf01 ethernet-1/1 vlan 100"*

**Resolution**: base interface `ethernet-1/1`; VLAN 100 → subinterface index `100`
(single-tagged, `vlan-id 100`); binding key `ethernet-1/1.100`; direction `input`; filter type
`ipv4`; filter name `t1-svc-0042-in` (sanitised, not derived — §1).

**Priority mapping** (§3, option B): the operator's one rule → `sequence-id 10`;
`defaultAction: deny` → reserved terminal `sequence-id 65535`.

### 9a. SR Linux flat `set /` configuration

```
# --- prerequisite: the subinterface must already exist (§5, option O1) ---
set / interface ethernet-1/1 admin-state enable
set / interface ethernet-1/1 vlan-tagging true
set / interface ethernet-1/1 subinterface 100 admin-state enable
set / interface ethernet-1/1 subinterface 100 type routed
set / interface ethernet-1/1 subinterface 100 vlan encap single-tagged vlan-id 100

# --- the filter ---
set / acl acl-filter t1-svc-0042-in type ipv4 description "tenant1/svc-0042 ingress"
set / acl acl-filter t1-svc-0042-in type ipv4 statistics-per-entry true

# rule 1 (operator): permit tcp 443 from 10.0.0.0/24
set / acl acl-filter t1-svc-0042-in type ipv4 entry 10 description "permit-https"
set / acl acl-filter t1-svc-0042-in type ipv4 entry 10 match ipv4 protocol tcp
set / acl acl-filter t1-svc-0042-in type ipv4 entry 10 match ipv4 source-ip prefix 10.0.0.0/24
set / acl acl-filter t1-svc-0042-in type ipv4 entry 10 match transport destination-port operator eq
set / acl acl-filter t1-svc-0042-in type ipv4 entry 10 match transport destination-port value 443
set / acl acl-filter t1-svc-0042-in type ipv4 entry 10 action accept

# the reserved terminal default-action entry (FR-041) — NOT optional: the device's
# own default for unmatched traffic is ACCEPT, so "deny everything else" is only
# true if this row exists
set / acl acl-filter t1-svc-0042-in type ipv4 entry 65535 description "default-deny"
set / acl acl-filter t1-svc-0042-in type ipv4 entry 65535 action drop

# --- the binding ---
set / acl interface ethernet-1/1.100 interface-ref interface ethernet-1/1
set / acl interface ethernet-1/1.100 interface-ref subinterface 100
set / acl interface ethernet-1/1.100 input acl-filter t1-svc-0042-in type ipv4
```

Notes on the exemplar:
- `action accept` and `action drop` are **presence containers** — in the CLI they take no value;
  in JSON they are empty objects.
- `destination-port` needs **both** `operator eq` and `value 443`; `operator` without `value`
  violates a `must` [VERIFIED: v25.7.1 line 668].
- `match ipv4 protocol tcp` is **required** for the port match to be legal at all
  [VERIFIED: the port `must` in §4].
- For an **egress** variant, add
  `set / acl acl-filter t1-svc-0042-in type ipv4 subinterface-specific output-only` (§6).
- `statistics-per-entry true` is what makes `matched-packets` exist (§7).

### 9b. JSON_IETF form (gNMI `Set`, `update` at prefix `/`)

```jsonc
{
  "srl_nokia-acl:acl": {
    "acl-filter": [
      {
        "name": "t1-svc-0042-in",
        "type": "srl_nokia-acl:ipv4",
        "description": "tenant1/svc-0042 ingress",
        "statistics-per-entry": true,
        "entry": [
          {
            "sequence-id": 10,
            "description": "permit-https",
            "match": {
              "ipv4": {
                "protocol": "tcp",
                "source-ip": { "prefix": "10.0.0.0/24" }
              },
              "transport": {
                "destination-port": { "operator": "eq", "value": 443 }
              }
            },
            "action": { "accept": {} }
          },
          {
            "sequence-id": 65535,
            "description": "default-deny",
            "action": { "drop": {} }
          }
        ]
      }
    ],
    "interface": [
      {
        "interface-id": "ethernet-1/1.100",
        "interface-ref": {
          "interface": "ethernet-1/1",
          "subinterface": 100
        },
        "input": {
          "acl-filter": [
            { "name": "t1-svc-0042-in", "type": "srl_nokia-acl:ipv4" }
          ]
        }
      }
    ]
  }
}
```

JSON_IETF encoding notes:
- `type` is an enum **imported into the leafref's own module**, so in strict JSON_IETF it is
  namespace-qualified as `"srl_nokia-acl:ipv4"`. SR Linux also accepts the bare `"ipv4"`; emit the
  qualified form, because sdcio validates against the schema. [UNVERIFIED: from memory — the
  qualified-vs-bare acceptance was not exercised on a device this session. The *requirement* to
  qualify identityref/enum values from a foreign module is standard RFC 7951, and qualifying is
  never wrong.]
- `sequence-id` is `uint32` → a JSON number. Ports are `uint16` → number. Counters read back as
  `uint64` → **JSON strings** per RFC 7951.
- `accept` / `drop` are presence containers → **`{}`**, never `true` and never `null`.
- Both filter and binding belong in **one** `SetRequest` so the transaction is atomic (§8).

### 9c. gnmic read-back commands

```bash
# ---------- configuration side (FR-042 side 1) ----------
gnmic -a leaf01:57400 -u admin -p "$PW" --skip-verify -e json_ietf \
  get --type config \
  --path '/acl/acl-filter[name=t1-svc-0042-in][type=ipv4]'

gnmic -a leaf01:57400 -u admin -p "$PW" --skip-verify -e json_ietf \
  get --type config \
  --path '/acl/interface[interface-id=ethernet-1/1.100]'

# ---------- applied side (FR-042 side 2) ----------
# A2 — THE load-bearing check: this entry occupies TCAM on the INPUT path,
#      which is only true if this filter is bound on input on this complex.
gnmic -a leaf01:57400 -u admin -p "$PW" --skip-verify -e json_ietf \
  get --type state \
  --path '/acl/acl-filter[name=t1-svc-0042-in][type=ipv4]/entry[sequence-id=10]/tcam-entries/forwarding-complex[complex-identifier=*]'
gnmic -a leaf01:57400 -u admin -p "$PW" --skip-verify -e json_ietf \
  get --type state \
  --path '/acl/acl-filter[name=t1-svc-0042-in][type=ipv4]/entry[sequence-id=65535]/tcam-entries/forwarding-complex[complex-identifier=*]'
#   assert input-total  > 0   on at least one complex   (A2)
#   assert output-total == 0                            (A3)
#   assert single-instance > 0                          (A1)

# A4 — the device's own per-subinterface view of THIS filter
gnmic -a leaf01:57400 -u admin -p "$PW" --skip-verify -e json_ietf \
  get --type state \
  --path '/acl/interface[interface-id=ethernet-1/1.100]/input/acl-filter[name=t1-svc-0042-in][type=ipv4]'

# per-entry counters (needs statistics-per-entry true)
gnmic -a leaf01:57400 -u admin -p "$PW" --skip-verify -e json_ietf \
  get --type state \
  --path '/acl/acl-filter[name=t1-svc-0042-in][type=ipv4]/entry[sequence-id=10]/statistics'

# G1 — the gate: no prior ACL transaction still landing
gnmic -a leaf01:57400 -u admin -p "$PW" --skip-verify -e json_ietf \
  get --type state \
  --path '/acl/datapath-programming/forwarding-complex[slot-id=*][complex-id=*]/programming-complete'

# optional: watch a rule get hit during the §6 traffic test
gnmic -a leaf01:57400 -u admin -p "$PW" --skip-verify -e json_ietf \
  subscribe --mode stream --stream-mode sample --sample-interval 5s \
  --path '/acl/acl-filter[name=t1-svc-0042-in][type=ipv4]/entry[sequence-id=*]/statistics/matched-packets'
```

[The path shapes are verified against the YANG tree; the gnmic flag spellings are standard
(`--type config|state`, `-e json_ietf`) — gnmic 0.47.0 is installed on this host but no device was
available to execute against this session. UNVERIFIED: that these exact command lines were run.]

### 9d. A compact enforcement test, if §6 option (a) is adopted

```bash
# from the client container attached to leaf01 ethernet-1/1 vlan 100
curl --max-time 3 https://10.20.0.10/           # expect: succeeds     (entry 10)
ping -w 2 -c 2 10.20.0.10                       # expect: 100% loss    (entry 65535)
# then assert both counters moved, on the entries we wrote:
gnmic … get --type state \
  --path '/acl/acl-filter[name=t1-svc-0042-in][type=ipv4]/entry[sequence-id=10]/statistics/matched-packets'
gnmic … get --type state \
  --path '/acl/acl-filter[name=t1-svc-0042-in][type=ipv4]/entry[sequence-id=65535]/statistics/matched-packets'
```
Modelled on `srl-labs/srl-acl-lab`, which does exactly this shape with ICMP
[VERIFIED: https://github.com/srl-labs/srl-acl-lab README].

---

## 10. Coupling-row and requirement disposition — the checklist

| Row / item | Disposition |
|---|---|
| **PC-06** (name derivation) | **Delete the derivation.** Replace with a sanitiser (1–255, `alphanumeric` pattern, no leading space) + reserved-name refusal (`system`, `capture`) |
| **PC-07** (no L2/MAC type) | **Rewrite.** `type mac` exists; the refusal is a scope decision, and is reinforced by MAC/IP mutual exclusion per subinterface-direction |
| **PC-08** (ICMPv6 excluded) | **Delete.** `next-header icmp6`/58 is first-class; D-15 correction #2 is reverted for this platform |
| **PC-09** (priority 1 reserved, 2–65535) | **Replace.** `sequence-id 0..65535`, **ascending** evaluation, first match wins, implicit default **accept**; **65535 reserved**, 0–65534 usable |
| **PC-10** (no table priority ⇒ refuse 2nd bind) | **Rewrite.** Refusal stands, reason changes to "the platform supports one filter of a type per subinterface per direction" |
| **PC-11** (CONFIG_DB/ASIC_DB, `redis-*` checks) | **Delete.** Replaced by keyed gNMI CONFIG/STATE reads (§7) |
| **PC-12** (GCU poisoning) | **Delete.** No such failure mode; gNMI transactions are isolated (§8) |
| **PC-13** (SAI bind-point type, stock-leaf baseline) | **Delete**, but carry its *lesson* forward: containerlab's stock `cpm` filter entries are the new "already there on an empty fabric" hazard (§7) |
| **PC-A-02** (port binding, "a port at a stage") | **Resolved.** Subinterface binding; exclusivity = **subinterface + direction + address family** |
| **Open decision 4** | **Answered** (§5): subinterfaces; FR-037 and FR-043 rewritten as drafted |
| **FR-037** | rewritten (§5) |
| **FR-039** | "lowest priority" → "highest sequence-id"; mapping direction stated |
| **FR-040** | ICMPv6 clause removed; "L4 port on a protocol that has none" → "TCP or UDP only"; add reserved-terminal-slot and reserved-name clauses; note 3 of the refusals are now device-enforced |
| **FR-041** | strengthened: the implicit default is **accept**, so an unrendered default is a silent permit |
| **FR-042** | two-sided survives; "configuration store / ASIC store" → "gNMI CONFIG / gNMI STATE"; the applied-side evidence is `tcam-entries/*/input-total` keyed by filter+type+entry+direction |
| **FR-043** | rewritten (§5) |
| **SC-014** | reword "as the device's own applied view of the filter, wherever the platform exposes one" → the platform does expose one, unconditionally; consider adding the enforcement clause from §6 |
| **SC-015** | unchanged, but note that several refusals are now belt-and-braces over device `must`s |
| **GAP-4** | unchanged in substance; **add a sibling**: `/acl/interface[…]` is a separate object from `/interface[…]`, so deletion ordering (binding → filter → subinterface owner) is now a stated requirement |
| **GAP-6** | **closeable.** SR Linux gives every construct the same `--type state` applied view; promote two-sided read-back to a construct-neutral requirement |
| **D-12** | **delete** |
| **D-13** | keep the determinism property; delete the derivation rationale |
| **D-14** | keep both mechanisms; change the rationale (as PC-10) and change the unit of exclusivity |
| **D-15** | keep the discipline; **replace the whole table** with §4's; revert correction #2 (ICMPv6), keep correction #1 (MAC) with a new reason |
| **D-16** | keep two-sided; replace the mechanism; the "carried defect" is **fixed by construction** because every applied-side path is keyed by filter name and type |
| **R-25** | **delete** (tombstone) |
| **R-26** | **closeable** — §7's A2/A3/A4 cannot pass switch-wide. Record the fix, and record the *new* stock-object hazard (`cpm`) that would recreate it if an unkeyed check were ever written |
| **Assumption** "access lists bind to ports only; VLAN-level binding out of scope" | **rewrite** — binding is to subinterfaces, and a VLAN-tagged subinterface *is* the VLAN-level case, demonstrated rather than guessed at |
| **Assumption** "proving enforcement … is out of scope" | **rewrite** — enforcement is demonstrable on containerlab SR Linux (§6); choose option (a) or (b) and say which |
| **Assumption** "scope is the match and action set the cited reference documents" | **keep** — it is now the *load-bearing* reason for the MAC and tcp-flags/dscp/ttl exclusions |

---

## 11. Residual unknowns, stated as unknowns

1. **Whether `interface-ref` is auto-derived from the `interface-id` key.** Nokia's own lab omits it
   [VERIFIED: srl-acl-lab `icmp_drop.cfg`]; the vendor guide sets it
   [VERIFIED: acl-25-3 guide]. The recommendation (always set it) is safe either way, but the
   underlying behaviour was not tested on a device this session. [UNVERIFIED]
2. **Which `if-feature`s the 7220 IXR-D2L container actually advertises** — in particular
   `acl-if-output-shared-tcam-entries` (which decides whether the egress `subinterface-specific`
   `must` bites) and `acl-subinterface-entry-statistics`. The feature names and the `must`s are
   verified from YANG; the per-platform feature file lives inside the image and was not read.
   **Recommend making this a capability-gate line item** (PC-02's successor): one `Get` on
   `/acl/acl-filter[…]/…` after a deliberate egress bind, on the pinned image, resolves it.
3. **Whether the D2L container's feature set enables `type mac`** (`platform-7220-d2` vs a
   hypothetical `-d2l`). Moot under the §2 recommendation, but it would matter if MAC were ever
   brought in scope. [UNVERIFIED]
4. **Exact JSON_IETF acceptance of a bare vs module-qualified `type` value.** [UNVERIFIED]
5. **Whether SR Linux 25.7.1's ACL module revision string differs from 25.3.1's.** It does not —
   the `srl_nokia-acl` module's newest revision in the `v25.7.1` tag is `2025-03-31 "SRLinux 25.3.1"`
   [VERIFIED: v25.7.1 `srl_nokia-acl.yang` lines 46–49], even though the file's *content* differs
   from v25.3.3 (the egress `must`, `choice port`, `ttl`, `hop-limit`, `ip-option-present`).
   **This matters**: the revision date is not a reliable compatibility key for this module, so the
   five-part compatibility set (PC-01) must pin the **YANG repository tag**, not the module revision.
