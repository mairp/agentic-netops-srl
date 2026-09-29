# Contract: access-list render and verification

**Feature**: `004-agentic-netops-composite` | **Carries**: FR-035 to FR-043, FR-097, FR-100 |
**Decisions**: D-13, D-14, D-15, D-16, RD-05, RD-12, RD-13

**Producer**: the provider's access-list renderer (`internal/render/srl/acl`) · **Write path**: an
SDC `Config` object rendered by `agentic-netops-srl-provider` and applied by the
device-configuration layer over gNMI (`JSON_IETF`, TLS, port 57400) · **Device**: Nokia SR Linux
`25.7.1` as pinned in the lock file.

Every path, key, type, range and `must` below is read off the pinned model set
(`srl_nokia/models/acl/srl_nokia-acl.yang` and `srl_nokia-packet-match-types.yang` at YANG tag
`v25.7.1`) rather than assumed: `evidence/03-acl.md` §1 to §9. **Everything in this document is
platform-specific**: [platform-coupling.md](../platform-coupling.md) PC-06, PC-07, PC-09, PC-10,
PC-A-02.

## 1. Write path — the same transaction as every other construct

An access list is ordinary native YANG configuration under `/acl`. It carries no special path, no
second client and no escape hatch.

- **As a property of a service** (FR-036), the filter and its binding are rendered into the **same**
  SDC `Config` for that node as the rest of the service, so they reach the device in one gNMI
  `SetRequest` alongside the network-instance and the subinterfaces they protect.
- **As a construct in its own right** (FR-035), the access list is its own `Config` object, one per
  (service, node), named `<source>.<node>` like every other (`contracts/crd-api.md`) and bound to
  its target by the `config.sdcio.dev/targetName` and `config.sdcio.dev/targetNamespace` labels, at
  the service priority band (`20`). It never carries an interface or a subinterface of its own —
  **nor the binding entry's `interface-ref`**: that pair of leaves is rendered by the `Config` that
  renders the subinterface, always and whether or not its service binds a filter, so a standalone
  list writes only its `input`\|`output` `acl-filter[name][type]` entry beneath an entry that already
  exists, and shares no leaf with the owner or with another standalone list on the same subinterface
  (FR-015, AD-68). That the pinned release accepts a binding entry with no filter is observed by
  gate item G9 before it is relied on.
- **Validated before any write.** The rendered configuration is validated against the pinned schema
  (`srl.nokia.sdcio.dev` `25.7.1`, built from the pinned YANG tag plus the pinned deviation commit)
  — offline in CI over every golden render, and again by the device-configuration layer before it
  opens a `SetRequest`. A request that would produce one of the device's own `must` failures is
  refused earlier still, at interpretation (§3), so the device error text is a backstop rather than
  the only line of defence.
- **A rejected access list fails its own transaction only.** gNMI on SR Linux applies a
  `SetRequest` inside a private exclusive candidate (`gnmirpc-<n>`); either every modification in
  the message is applied or the candidate is discarded and the running datastore is untouched. No
  later transaction — for this access list, for this service, or for any other construct on the
  node — is affected. There is no image-wide poisoning mode on this platform
  (`evidence/03-acl.md` §8).

*History: on the predecessor platform an access list was forced onto a raw key-value store because a
whole-config write carrying its port leafref could poison every subsequent write image-wide. No raw
store, no whole-config/raw split and no executor exists here; D-12, R-25, PC-11 and PC-12 are
retired with the mechanism that required them.*

## 2. Objects

### `/acl/acl-filter[name=<F>][type=<T>]`

**The key is the pair `name type`** — every render, read-back, rollback and check entry in this
contract carries `[name=…][type=…]`. A filter is not addressable by name alone.

| Field | Value |
|---|---|
| `name` | `acl-<serviceId>-<stage>` — deterministic, derived identically by apply, verify and rollback (D-13) |
| `type` | `ipv4` \| `ipv6`. `mac` is refused as out of scope (§3) |
| `description` | `<tenant>/<serviceId> <stage>`, ≤255 characters |
| `statistics-per-entry` | **`true` on every rendered filter** — without it `matched-packets` and `last-match` are never populated and no hardware resource is allocated to collecting them |
| `subinterface-specific` | `output-only`, or `input-and-output` when the same filter is also bound on ingress — **rendered whenever `stage: egress`** (§3, §4) |

**Name rule** (`srl_nokia-comm:name`): 1–255 characters, from the alphanumeric-plus-punctuation
alphabet, and **the first character must not be a space**. The renderer **sanitises and refuses; it
never silently rewrites**, because a rewritten name breaks the apply/verify/rollback agreement that
D-13 exists to protect. The names **`system` and `capture` are reserved** by the device for system
filters and packet-capture filters and are refused by name (`must`-enforced on the device).

### `entry[sequence-id=<S>]`

| Field | From | Notes |
|---|---|---|
| `sequence-id` | `rule.priority`, **unchanged** | Identity mapping. Usable **1–65534**; **65535 is reserved** for the default action. Evaluated in **ascending** order, first match wins — priority 100 is evaluated before priority 200 |
| `description` | `rule.name` | The operator's rule name lives here. The **identity** of an entry is its `sequence-id`, not its name |
| `action/accept{}` \| `action/drop{}` | `rule.action` | permit → `accept`, deny → `drop`. Both are **presence containers**: `{}` in JSON, no value in the CLI |
| `match/ipv4/protocol` \| `match/ipv6/next-header` | `rule.protocol` | A known name or a number 0–255. `icmp6`/58 is first-class and accepted |
| `match/ipv4/source-ip/prefix` \| `match/ipv6/source-ip/prefix` | `rule.sourcePrefix` | The `prefix` form only; address+inverse-mask and `prefix-list` are out of scope |
| `…/destination-ip/prefix` | `rule.destinationPrefix` | as above |
| `match/transport/source-port/{operator,value}` | `rule.sourcePort`, single | `operator: eq` and `value` are both required; `operator` without `value` violates a `must` |
| `match/transport/source-port/range/{start,end}` | `rule.sourcePort`, `lo-hi` | mutually exclusive with `operator`/`value` |
| `match/transport/destination-port/…` | `rule.destinationPort` | same two forms |

Ports are rendered as **numbers**, never as the device's well-known-name enumeration: that enum set
is release-dependent and a name is not a stable contract.

The `match/ipv4` and `match/ipv6` containers are the address-family discriminator — every leaf under
`match/ipv4/` carries `must "…/type = 'ipv4'"` and vice versa, so a wrong-family prefix is rejected
by the device as well as refused by the platform (§3).

### The default-action entry (FR-041)

**The device's implicit behaviour for unmatched traffic is ACCEPT.** A declared `defaultAction`
renders as a terminal, match-all entry at the reserved `sequence-id 65535`:

- `defaultAction: deny` → `entry 65535 { action { drop { } } }`. Without this row "deny everything
  else" is not true — the device permits everything the rules did not name.
- `defaultAction: permit` → `entry 65535 { action { accept { } } }`. Behaviourally identical to the
  implicit default, and rendered anyway so the read-back in §4 has a row to assert and the check set
  is symmetric across both default actions.
- **When no default action is declared**, nothing is rendered at 65535 and the platform owes the
  operator a statement: the first confirmation MUST say that unmatched traffic is accepted by the
  device's own default, and the platform MUST NOT describe the list as restrictive beyond its
  explicit rules (FR-041). The confirmation also states the evaluation order (ascending priority,
  first match wins) and the usable range (FR-039).

### `/acl/interface[interface-id=<IF>.<IDX>]`

| Field | Value |
|---|---|
| `interface-id` | `"<interface>.<subinterface-index>"`, e.g. `ethernet-1/1.100` — the device's documented convention, so `info` output is legible |
| `interface-ref/interface` | the base interface, e.g. `ethernet-1/1` — **always written explicitly**, by the `Config` that renders the subinterface (AD-68) |
| `interface-ref/subinterface` | the subinterface index, e.g. `100` — **always written explicitly**, by the same `Config` |
| `input/acl-filter[name=<F>][type=<T>]` | the binding, when `stage: ingress` |
| `output/acl-filter[name=<F>][type=<T>]` | the binding, when `stage: egress` |

**Stage mapping: `ingress` → `input`, `egress` → `output`.**

`interface-id` is a free string key with no leafref and no `must`; `interface-ref` is
leafref-checked against `/interface[name]/subinterface[index]`. Writing `interface-ref` is therefore
what makes the device prove the binding target exists, instead of accepting a string that merely
looks right and binds nothing. Binding by `interface-id` alone is forbidden for exactly that reason.

The operator names **node + port (+ VLAN)**; the site inventory resolves that to
`(interface, subinterface-index)`, with **no VLAN → subinterface `0`** (FR-037).

### 2.1 Golden exemplar

**Operator intent**: *"permit tcp 443 from 10.0.0.0/24, deny everything else, ingress, ipv4, on
leaf01 ethernet-1/1 vlan 100"*, for service `svc-0042`, tenant `tenant1`.

**Resolution**: base interface `ethernet-1/1`; VLAN 100 → subinterface index `100`; binding key
`ethernet-1/1.100`; direction `input`; filter type `ipv4`; filter name `acl-svc-0042-ingress`.
**Ordering**: the operator's `priority: 100` → `sequence-id 100` (identity); `defaultAction: deny`
→ the reserved terminal `sequence-id 65535`.

#### 2.1a Flat `set /` form

```text
# --- prerequisite: the port's own leaves are the fabric Config's (priority 10, AD-68) ...
set / interface ethernet-1/1 admin-state enable
set / interface ethernet-1/1 vlan-tagging true
# --- ... and the subinterface already exists, created by the owning service (bridged or routed
#     as that service requires) together with its binding entry's interface-ref.
#     An access list never creates either.
set / interface ethernet-1/1 subinterface 100 admin-state enable
set / interface ethernet-1/1 subinterface 100 vlan encap single-tagged vlan-id 100

# --- the filter ---
set / acl acl-filter acl-svc-0042-ingress type ipv4 description "tenant1/svc-0042 ingress"
set / acl acl-filter acl-svc-0042-ingress type ipv4 statistics-per-entry true

# rule: permit tcp 443 from 10.0.0.0/24   (operator priority 100 -> sequence-id 100)
set / acl acl-filter acl-svc-0042-ingress type ipv4 entry 100 description "permit-https"
set / acl acl-filter acl-svc-0042-ingress type ipv4 entry 100 match ipv4 protocol tcp
set / acl acl-filter acl-svc-0042-ingress type ipv4 entry 100 match ipv4 source-ip prefix 10.0.0.0/24
set / acl acl-filter acl-svc-0042-ingress type ipv4 entry 100 match transport destination-port operator eq
set / acl acl-filter acl-svc-0042-ingress type ipv4 entry 100 match transport destination-port value 443
set / acl acl-filter acl-svc-0042-ingress type ipv4 entry 100 action accept

# the reserved terminal default-action entry (FR-041) — NOT optional: the device's own
# default for unmatched traffic is ACCEPT, so "deny everything else" is only true if
# this row exists
set / acl acl-filter acl-svc-0042-ingress type ipv4 entry 65535 description "default-deny"
set / acl acl-filter acl-svc-0042-ingress type ipv4 entry 65535 action drop

# --- the binding ---
set / acl interface ethernet-1/1.100 interface-ref interface ethernet-1/1
set / acl interface ethernet-1/1.100 interface-ref subinterface 100
set / acl interface ethernet-1/1.100 input acl-filter acl-svc-0042-ingress type ipv4
```

For the **egress** variant, `input` becomes `output` and the filter additionally carries
`set / acl acl-filter acl-svc-0042-egress type ipv4 subinterface-specific output-only`.

#### 2.1b `JSON_IETF` form — the golden-file shape

```jsonc
{
  "srl_nokia-acl:acl": {
    "acl-filter": [
      {
        "name": "acl-svc-0042-ingress",
        "type": "srl_nokia-acl:ipv4",
        "description": "tenant1/svc-0042 ingress",
        "statistics-per-entry": true,
        "entry": [
          {
            "sequence-id": 100,
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
        "interface-ref": { "interface": "ethernet-1/1", "subinterface": 100 },
        "input": {
          "acl-filter": [
            { "name": "acl-svc-0042-ingress", "type": "srl_nokia-acl:ipv4" }
          ]
        }
      }
    ]
  }
}
```

Encoding rules the golden files depend on:

- `accept` and `drop` are **presence containers** → `{}`. Never `true`, never `null`.
- `sequence-id` (`uint32`) and port values (`uint16`) are JSON **numbers**; the `uint64` counters
  read back as JSON **strings** per RFC 7951.
- The enum `type` is emitted **module-qualified** (`"srl_nokia-acl:ipv4"`). The exact serialization
  form the device returns from a real `Get` is a capability-gate item (RD-12 G12) and is observed
  **before any golden file is frozen**, because an unqualified round-trip would break idempotence
  (NFR-001, R-36). G12 observed the module-prefixed form, and the goldens freeze it, as decided
  (AD-81).
- The filter and its binding belong in **one** `SetRequest`, so the pair is atomic.

## 3. What is refused by name

Refusals are pre-submission and all-or-nothing (SC-015, FR-045). Several are also enforced by the
device's own `must` statements; those rows are marked, and the platform still refuses first so that
nothing is created on the fabric before the cause is named.

| Asked for | Refused because | Requirement | Device-enforced? |
|---|---|---|---|
| filter `type: mac`, or a Layer 2 access list | out of declared scope — this construct is defined over address families; the device does offer `type mac`, and admitting it would also make the exclusivity unit coarser, because the device forbids a MAC filter and an IP filter on one subinterface in one direction | FR-038 | no — the device supports it; the refusal is scope |
| a list named `system` or `capture` | reserved on this platform for system filters and packet-capture filters | FR-040 | **yes**, `must` |
| a rule at the reserved position `65535` | reserved for the default action; the refusal states that **1–65534** is usable | FR-040 | no — this contract's convention, matching the device's own documented idiom |
| duplicate priorities, or duplicate rule names, within one list | which of a permit and a deny wins would be decided arbitrarily | FR-040 | list-key uniqueness catches the first; the second is this platform's |
| a prefix in the wrong address family for the list type | an `ipv4` match leaf requires `type = 'ipv4'`, and vice versa; the entry would be programmed and never match | FR-040 | **yes**, `must` |
| an L4 port or port range on any protocol other than **TCP (6) or UDP (17)** | the device admits only 6 and 17 for a port match — note this excludes SCTP, which has ports | FR-040 | **yes**, `must` |
| `tcp-flags`, `dscp`, `ttl`, `hop-limit`, `fragment` / `first-fragment`, `ip-option-present`, ICMP/ICMPv6 `type` and `code` | out of the declared match set | FR-040 | no |
| `log: true` | on this platform no log is generated for accept-on-input, accept-on-output or drop-on-output; offering a flag that silently does nothing in three of four combinations is an overclaim | FR-040 | no — a silent no-op, which is why it is refused rather than passed through |
| mirror sessions, policers and rate limiting, `copy`, `forward next-hop`, forwarding-class or profile actions, policy-based forwarding | out of scope; no redirect action is offered | FR-040 | `copy` yes (`must` ties it to the `capture` filter); the rest no |
| a control-plane (`cpm`), `system` or `capture` filter of any kind | those filters are the device's and containerlab's own; the platform neither writes nor counts them | FR-040 | partly |
| a `prefix-list` reference instead of an inline prefix | a second named object with its own lifecycle | FR-040 | no |
| binding to a network instance, to a VLAN as such, to an integrated-routing (IRB) subinterface, or fabric-wide | the binding point is a named attachment subinterface; the refusal says so. IRB subinterfaces are bindable on the device but are **not** in the operator vocabulary here, and are never fanned out implicitly from a service | FR-037 | **yes**, structurally — `/acl/interface` binds through a subinterface leafref and nothing else |
| a standalone access list on a node, port and VLAN where no subinterface exists | a standalone list binds to an attachment another service already created; it never creates one. The refusal names the missing subinterface. The VLAN it names is a reference, so a subinterface whose VLAN the authority allocated (`1000–4000`) is bound like any other — the naming band and the claim gate do not apply to it (AD-47) | FR-035 | **yes** at commit (the leafref fails) — but refused before submission |
| `stage: egress` when the qualification record does not show egress qualified on the pinned profile | the pinned profile's egress capability (the `subinterface-specific` requirement and the output-direction feature set) is a gate item; an unqualified property is refused at interpretation, naming it, before any identifier is claimed | FR-097 | conditional `must` on the device |
| a second access list on a subinterface that already carries one in the same direction for the same address family | the platform accepts exactly one filter of an address family per subinterface per direction, so a second is unsupported, not merely ambiguous. The refusal names the holding service | FR-043 | yes on this platform family |

**`protocol: icmpv6` is ACCEPTED.** `next-header icmp6` (58) is a first-class value on this device,
and any IP protocol number 0–255 the device can match is accepted (FR-040). The predecessor
platform's ICMPv6 refusal was a property of that device's protocol range; it has no basis here and
is not reinstated. *(D-15 correction #2 is reverted for this platform; correction #1 — the MAC
refusal — survives with the new reason in the first row.)*

The device's own refusal texts, which a correct render must never provoke, are:
`"The protocol or next-header must be TCP or UDP to use port value"`,
`"The acl-filter must be of type ipv4"` / `"… of type ipv6"`,
`"The acl-filter name must not be system or capture"`,
`"ACL allowed with subinterface type bridged or routed"`,
`"IP ACLs not allowed on loopback subinterface"`, and
`"On the current platform, subinterface-specific must be set to output-only or input-and-output for
egress filters."`

## 4. Verification (FR-042, FR-100)

Emitted as check entries on the service's status; a service whose checks fail is not `Ready`.
Verification is **two-sided** and, on this device, both sides live in **one datastore read through
two gNMI datastore types**: `config true` nodes are the intent, `config false` nodes are the applied
view. As decided, the provider's read-back takes the written side from the running datastore as the
device-configuration layer holds it and the applied side from the **device metric collector** — the
pinned data-server serves no state datastore (AD-82 `2026-09-21-state-source`); the gate (G9) reads
the same keyed paths device-direct with `--type state`. **Passing only the written side is not convergence** — the device commits configuration the
forwarding complex may still be programming.

**Every applied-side path is keyed by filter name, filter type and entry sequence-id.** A
device-wide or fabric-wide count is never evidence (FR-042, FR-100).

### 4.1 Gate — once per node, before the per-filter checks

| # | Path (`--type state` in the gate; the device metric collector in the read-back — AD-82 `2026-09-21-state-source`) | Assert |
|---|---|---|
| G1 | `/acl/datapath-programming/forwarding-complex[slot-id=*][complex-id=*]/programming-complete` | `true` on every complex — no prior access-list transaction is still landing |

### 4.2 Written side — SDC `Config` and the running datastore (`--type config`)

| # | Check | Asserts |
|---|---|---|
| W0 | the service's SDC `Config` for this node reports `Ready`, with **no** `Deviation` on a path this render owns | the transaction was accepted and nothing has drifted |
| C1 | `/acl/acl-filter[name=F][type=T]` exists | the filter was written |
| C2 | `/acl/acl-filter[name=F][type=T]/entry[sequence-id=S]/action/{accept\|drop}` | the declared action's presence container, per rendered rule |
| C3 | `/acl/acl-filter[name=F][type=T]/entry[sequence-id=S]/match/…` | each declared match field equals the rendered value |
| C4 | `/acl/acl-filter[name=F][type=T]/entry[sequence-id=65535]/action/{accept\|drop}` | the terminal default-action entry, whenever a default action was declared |
| C5 | `/acl/interface[interface-id=IF.IDX]/interface-ref/{interface,subinterface}` | equals the resolved base interface and subinterface index |
| C6 | `/acl/interface[interface-id=IF.IDX]/<input\|output>/acl-filter[name=F][type=T]` | the binding is present in the declared direction, and not in the other — the keyed binding is **judged here, in running**: SR Linux 25.7.1 mirrors no part of `/acl/interface` into state (AD-79, AD-82 `2026-09-21-acl-binding-state`) |
| C7 | `/acl/acl-filter[name=F][type=T]/subinterface-specific` | `output-only` or `input-and-output`, **when `stage: egress`** |

### 4.3 Applied side — the device's own state (`--type state` in the gate; the device metric collector in the read-back — AD-82 `2026-09-21-state-source`)

| # | Path | Assert |
|---|---|---|
| A1 | `/acl/acl-filter[name=F][type=T]/entry[sequence-id=S]/tcam-entries/forwarding-complex[complex-identifier=*]/single-instance` | `> 0` on at least one complex, for **every** rendered entry including 65535 — the entry has a real cost, i.e. it is programmable |
| A2 | the same path's `input-total` (ingress) **or** `output-total` (egress) | `> 0` on at least one complex, for **every** rendered entry — **this filter is bound in the declared direction and this entry occupies real forwarding-table space on that path** |
| A3 | the same path's **opposite**-direction total | `== 0` — the filter is not bound in a direction the operator did not ask for |
| A4 | the binding **shown applied by traffic** (AD-79 as decided by AD-82 `2026-09-21-acl-binding-state`): traffic entering on exactly the bound subinterface, then `/acl/acl-filter[name=F][type=T]/entry[sequence-id=10]/statistics/matched-packets` — this filter's **own** entry 10, keyed by filter name, type and sequence-id | rises above a baseline read before the traffic (`tests/gate/lib/checks.sh` `chk_acl_matched`; negative control `G9-acl-matched` on the stock node). Judged at G9 and in acceptance, never in a `Network`'s readiness read-back. The keyed binding in state (`/acl/interface[interface-id=IF.IDX]/<dir>/acl-filter[name=F][type=T]`) and the per-subinterface entry list (`…/entry[sequence-id=S]`) are **recorded, never judged** — 25.7.1 mirrors neither into state |
| A5 | `/acl/acl-filter[name=F][type=T]/entry[sequence-id=S]/statistics/{matched-packets,last-match,incomplete}` | readable, and `incomplete` not `true` — no complex ran out of statistics resources. Requires `statistics-per-entry true` |

**A2 is the load-bearing clause.** It cannot pass on an unprovisioned node, because there is no
filter of that name and type to read. It cannot be satisfied by another service's filter, because
the name and the type are in the path key. It cannot be satisfied by the device's own control-plane
filters, because those are named `cpm`. And it cannot be satisfied by a filter that was written but
never bound, because the direction totals read `0` in exactly that case. *(R-26 is closed by
construction: it is not possible to write a device-wide version of this check by accident.)*

**`matched-packets > 0` is never a readiness condition.** A correctly programmed filter on a quiet
link has zero matches; a readiness check that requires traffic is a flake generator. Only the
counter's existence and non-`incomplete`-ness are asserted here. Counter **movement** belongs to
acceptance (SC-041) and to the gate's A4 above, which drives its own traffic; neither is readiness.

### 4.4 Commands

```bash
# ---------- written side ----------
gnmic -a leaf01:57400 -u admin -p "$PW" --skip-verify -e json_ietf \
  get --type config \
  --path '/acl/acl-filter[name=acl-svc-0042-ingress][type=ipv4]'

gnmic -a leaf01:57400 -u admin -p "$PW" --skip-verify -e json_ietf \
  get --type config \
  --path '/acl/interface[interface-id=ethernet-1/1.100]'

# ---------- applied side ----------
# A1/A2/A3 — per entry, per direction, keyed by filter name and type
gnmic -a leaf01:57400 -u admin -p "$PW" --skip-verify -e json_ietf \
  get --type state \
  --path '/acl/acl-filter[name=acl-svc-0042-ingress][type=ipv4]/entry[sequence-id=100]/tcam-entries/forwarding-complex[complex-identifier=*]'
gnmic -a leaf01:57400 -u admin -p "$PW" --skip-verify -e json_ietf \
  get --type state \
  --path '/acl/acl-filter[name=acl-svc-0042-ingress][type=ipv4]/entry[sequence-id=65535]/tcam-entries/forwarding-complex[complex-identifier=*]'
#   assert single-instance > 0 (A1); input-total > 0 (A2); output-total == 0 (A3)

# A4 — the binding shown applied by traffic (AD-82 2026-09-21-acl-binding-state):
#   read entry 10's matched-packets (baseline), send traffic in on exactly ethernet-1/1.100,
#   read it again — it must rise above the baseline
gnmic -a leaf01:57400 -u admin -p "$PW" --skip-verify -e json_ietf \
  get --type state \
  --path '/acl/acl-filter[name=acl-svc-0042-ingress][type=ipv4]/entry[sequence-id=10]/statistics/matched-packets'
# recorded, never judged — 25.7.1 mirrors no part of /acl/interface into state
gnmic -a leaf01:57400 -u admin -p "$PW" --skip-verify -e json_ietf \
  get --type state \
  --path '/acl/interface[interface-id=ethernet-1/1.100]/input/acl-filter[name=acl-svc-0042-ingress][type=ipv4]'

# A5 — per-entry statistics
gnmic -a leaf01:57400 -u admin -p "$PW" --skip-verify -e json_ietf \
  get --type state \
  --path '/acl/acl-filter[name=acl-svc-0042-ingress][type=ipv4]/entry[sequence-id=100]/statistics'

# G1 — the gate
gnmic -a leaf01:57400 -u admin -p "$PW" --skip-verify -e json_ietf \
  get --type state \
  --path '/acl/datapath-programming/forwarding-complex[slot-id=*][complex-id=*]/programming-complete'
```

The path shapes are read from the pinned YANG tree and the flag spellings are gNMIc `0.47.0`'s;
**no device was available when they were drafted**, so the exact invocations are re-observed at P0
as part of the capability gate (RD-12 G9).

### 4.5 The negative control (NFR-013), and why a device-wide count is forbidden

**This check set counts only once it has been shown to FAIL on a stock leaf.** Before any pass is
recorded, the same commands are run against a freshly started SR Linux node carrying no
platform-written access list, and every per-filter check must return "not found" or a zero total.
The negative control is captured by the run that claims it — command, UTC time, exit status, image
digest, lab identity — like every other proof (NFR-013, SC-040).

**A stock leaf is not empty.** containerlab writes control-plane filter entries into the factory
configuration of every SR Linux node it starts — `acl-filter cpm type ipv4` entries for telnet and
for the plaintext gNMI port, plus IPv6 equivalents — on top of the several dozen `cpm` entries the
image itself ships with. **"Count the filters" or "count the entries" passes on a stock leaf with
roughly eighty entries and zero platform filters.** That is the same defect the predecessor
platform's switch-wide applied-side check had, with a different stock object. Every row in §4.3 is
keyed for exactly this reason, and **any unkeyed access-list check is a defect on sight.**

### 4.6 Residual unknowns, carried to P0

1. **Which `if-feature`s the pinned `ixr-d2l` container advertises** — in particular
   `acl-if-output-shared-tcam-entries` (which decides whether the egress `subinterface-specific`
   requirement bites) and `acl-subinterface-entry-statistics` (which A4 and the per-subinterface
   counters depend on). The feature names and the `must` statements are read from the pinned YANG;
   the per-platform feature file lives inside the image and has not been read. One deliberate egress
   bind plus one `Get` on the pinned image resolves it. **Gate item RD-12 G9; it also decides
   whether `stage: egress` is qualified at all (FR-097).** *Decided:* the record publishes
   `acl.egress` **unqualified** on this fabric — the pinned data-server refuses the egress binding's
   `must` although the render satisfies it, and G9 passed egress device-direct only — so
   `stage: egress` is refused by name at interpretation (FR-097). A4 is no longer the per-subinterface
   entry list (§4.3, AD-82 `2026-09-21-acl-binding-state`).
2. **The exact leaf names and shapes observed for the TCAM/programmed state on the pin.** The paths
   above are the model's; the values a container actually reports are observed at P0 before this
   check set is built. If the container programs no per-entry state, **this section is revised in
   the open — FR-042 is not weakened to make a check pass.**
3. **Whether `interface-ref` is auto-derived from the `interface-id` key.** Writing it explicitly is
   safe either way, and this contract writes it; the underlying behaviour has not been observed.

### 4.7 Enforcement — acceptance only (SC-041)

The containerized dataplane on this platform is a real emulated forwarding plane and **does** enforce
access lists; the device vendor's own access-list lab is a ping-drop test. Acceptance therefore
includes, for one access list in each direction the pinned profile qualifies, a probe the list
denies and a probe it permits, asserting both outcomes **and** the per-entry `matched-packets` delta
on exactly the entries this platform wrote.

**This probe is acceptance, never readiness** (FR-042). A traffic generator failure must never make
a correctly provisioned service report unready, and traffic tests on this lab assert reachability,
isolation and counter movement — **never throughput**, which the containerized dataplane does not
provide (FR-020, NFR-004).

## 5. Withdrawal and rollback

`/acl/interface[…]` is a **separate top-level object** from `/interface[…]`, so order matters: a
subinterface deleted while a binding still references it leaves a dangling leafref.

```text
1. delete /acl/interface[interface-id=IF.IDX]/<input|output>/acl-filter[name=F][type=T]
2. delete /acl/acl-filter[name=F][type=T]
3. only then, whatever owns the subinterface
```

In practice this is a removal of the paths from the owning `Config` object, applied by the
device-configuration layer in one transaction, and — for a tier-submitted service — a
label-selector rollback of the owning object under FR-065 to FR-067. Nothing the device itself owns
is ever deleted; no other service's filter or binding is read-modify-written, so withdrawing one
service's list cannot disturb another's (FR-043).

**Foreign-holder finalizer rule (FR-043, closes GAP-4).** A service whose attachment subinterface
carries **another** service's standalone access list MUST NOT finalize until that list is withdrawn.
The finalizer surfaces the holder **by name** in the condition rather than blocking silently, and a
holder that is itself being removed — one carrying a deletion timestamp — **still holds its
bindings until it is gone**; the refusal says so rather than treating the binding as already
released.

## 6. Cross-service binding conflict (FR-043)

**Unit of exclusivity: `(node, base interface, subinterface index, direction, address family)`.**

Concretely, `leaf01 / ethernet-1/1 / 100 / input / ipv4`. This is the finest unit that is actually
exclusive on the device, and it is deliberately finer than "a port at a stage": two services MAY
share a physical port at the same stage when they own **different subinterfaces**, or **different
address families** on the same subinterface. An untagged bind (`ethernet-1/1.0`) and a `vlan 100`
bind (`ethernet-1/1.100`) on one port do not conflict.

Detection is in two places, deliberately:

1. **Pre-flight**, before anything is applied: the deployer enumerates the service intent objects in
   the intent namespace and refuses a request that would take an exclusivity key another service
   already holds, **naming the holding service**. A holder with a deletion timestamp is still a
   holder, and the refusal says the holder is being removed.
2. **The renderer guard** is the belt to that pre-flight's braces: the pre-flight sees the cluster,
   the renderer sees one object, and only the renderer reaches the device.

The device is the third line and it is not ambiguous: this platform family accepts **one filter of a
given address family per subinterface per direction**. A second binding is not merely undefined in
its evaluation order — it is unsupported. An existing binding is never displaced, never merged into,
and never joined by a second list.
