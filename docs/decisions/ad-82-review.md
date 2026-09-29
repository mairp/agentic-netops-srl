# Decisions made under AD-82, for the operator's review

AD-82 (research.md, 2026-09-21) lets the build decide a live finding that contradicts an assumption
of the artefacts, if the decision keeps the requirement's intent. Each decision is recorded in
[`live-findings.md`](./live-findings.md) with the run's evidence cited by path and SHA-256, and
listed here for the operator at closing (T155, T188; CR-007, Principle I). None of them waives a
gate, relaxes a requirement or renumbers an identifier. "Where recorded" names the
`live-findings.md` table that holds the row with its evidence, plus the artefacts that state the
decision (T188).

Tables in `live-findings.md`: **A** = §Decisions made by the build under AD-82; **B** = §Decisions
found in the build record but not yet listed above (appended at closing, T188); **C** = §Decisions
made by the build under AD-82 during P11 (Phase 15).

**Count: 37 decisions.** 36 are awaiting operator review. 1 (`2026-09-21-gate-host-ping`) is open
and needs the operator's decision. Four rows of table B (`2026-09-21-unnumbered-admin-state`,
`2026-09-21-g10-liveness`, `2026-09-21-watchlist-client`, `2026-09-21-schema-recycle-failed`) were
made before AD-82 existed. They are recorded the way AD-82 records a decision.

| # | Slug | Date | Decision (one line) | What it limits | Where recorded | Status |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | `2026-09-21-feature-guarded-must` | 2026-09-21 | A first-party deviation module deletes the two feature-guarded vxlan-interface `must`s that the pinned data-server evaluates unconditionally. It is served by the in-cluster mirror at a content-pinned tag. The upstream patch stays at its locked commit | No `mac-vrf`/`ip-vrf` could apply until the module was loaded and G10 was re-run | live-findings A; plan.md part 3 and G10 row; spec.md FR pins; data-model.md `Schema` row; quickstart.md §TargetsReady | awaiting operator review |
| 2 | `2026-09-21-state-source` | 2026-09-21 | The read-back's applied side reads device state from the device metric collector (gNMIc → OTel Collector → Prometheus exporter), because the pinned layer serves no state datastore | Applied-side values are sampled, not read on demand. A lost invariant is seen within one re-verification interval plus 20 s (after `collector-freshness`) | live-findings A; spec.md FR-100, plan.md, data-model.md §13, §18, quickstart.md, acl-render-contract.md §4 | awaiting operator review |
| 3 | `2026-09-21-target-namespace` | 2026-09-21 | The onboarding set, the `Target`s and the layer's copy of `srl-credentials` live in `agentic-netops-system`. The layer's workloads and the schema mirror stay in `sdc-system` | T037's "`srl-credentials` in `sdc-system`" reads `agentic-netops-system` for the layer's copy | live-findings A; plan.md §Project structure; data-model.md `Schema` row; quickstart.md §3; kubernetes-objects.md namespaces; crd-api.md `Config` example | awaiting operator review |
| 4 | `2026-09-21-gate-rerun` | 2026-09-21 | On a lab that already carries the platform fabric, `GateReady` reuses the published record only if it is a pass by this gate's code (`gate_tree_sha256`) for this cluster, lab and image digest | A changed gate, image or lab never inherits an old pass. A first bring-up always runs the full gate | live-findings A | awaiting operator review |
| 5 | `2026-09-21-acl-binding-state` | 2026-09-21 | 25.7.1 mirrors no part of `/acl/interface` into state. A1–A3 stay as they are, and A4 (AD-79) becomes the binding shown applied by traffic (the filter's own entry-10 `matched-packets` above a baseline) | Behavioural evidence replaces a state mirror that does not exist. No device-wide count is used | live-findings A; acl-render-contract.md §4.3; plan.md G9; spec.md FR-004; quickstart.md §12 | awaiting operator review |
| 6 | `2026-09-21-build-context` | 2026-09-21 | `.dockerignore` excludes `tests/`, `docs/` and `specs/` from the provider's build context, so a gate run no longer changes the provider's content hash | A later root-context image that needs one of those trees must un-ignore it in the same change | live-findings A | awaiting operator review |
| 7 | `2026-09-21-schema-reload` | 2026-09-21 | Provisioning recycles a Ready `Schema` whose loaded refs differ from the manifest, then restarts the data server | A `Schema` change costs one data-server restart | live-findings A; plan.md part 3 | awaiting operator review |
| 8 | `2026-09-21-access-port-mtu` | 2026-09-21 | The fabric renders `mtu = portMTU` (9412) on every access port as well, and the routed service subinterface states the tenant `ip-mtu` | CR-009's "fabric port MTU" reads as every port the fabric owns | live-findings A; spec.md CR-009; data-model.md §13, §20 | awaiting operator review |
| 9 | `2026-09-21-mgmt-cut` | 2026-09-21 | The management cut is link-level: the host-side veth peer is set down (fault `mgmt-link-down`, revert `host-link-up`). It is not `docker network disconnect` | Only runs after the change count as SC-008/SC-043/SC-044 evidence | live-findings A; quickstart.md §SC-043 | awaiting operator review |
| 10 | `2026-09-21-collector-freshness` | 2026-09-21 | gNMIc samples every 5 s (was 10 s), and the exporter drops a series not refreshed within 20 s (was 45 s) | Twice the sample rate on the one telemetry session per device. SC-044's bound is unchanged | live-findings A; spec.md FR-100; plan.md; data-model.md §21 | awaiting operator review |
| 11 | `2026-09-24-layer-before-target` | 2026-09-24 | A Ready `Network` whose `Config` the layer no longer confirms, with nothing written this reconcile, counts as a read-back that cannot run (`Ready=Unknown`, `Degraded=True`, `VerificationFailed`) | SC-008's bound is met by the layer's `Config` status, not the `Target`'s. The `Target` latency is still recorded | live-findings A; spec.md; data-model.md §18; quickstart.md §SC-008 | awaiting operator review |
| 12 | `2026-09-24-vtep-teardown` | 2026-09-24 | A remote VTEP's zero index whose route evidence (IMET multicast destination) is absent in the same pass is reported `RoutesMissing`, not `NotProgrammed` | No criterion or bound changes | live-findings A; data-model.md §18 | awaiting operator review |
| 13 | `2026-09-24-unknown-retry` | 2026-09-24 | A `Network` held at `Ready=Unknown` retries its read-back at the reconciliation interval (15 s) | Read-back attempts every 15 s while a target is away (one collector read each) | live-findings A; spec.md; plan.md; data-model.md §19 | awaiting operator review |
| 14 | `2026-09-24-overlay-reconvergence` | 2026-09-24 | `reverify.sh`'s test `REVERIFY_INTERVAL` is 120 s (a 135 s bound), which covers the device's own BGP reconvergence | The accelerated run proves the schedule, not a faster recovery | live-findings A; quickstart.md §SC-044 | awaiting operator review |
| 15 | `2026-09-24-delete-unreachable` | 2026-09-24 | The finalizer asks the collector-based data-path probe about each node with a Ready `Target`. A node with no sample within 30 s counts as unreachable | A force-released node's stale configuration is removed by the layer when the node returns | live-findings A; spec.md FR-103; plan.md; data-model.md §18 | awaiting operator review |
| 16 | `2026-09-24-loopback-listeners` | 2026-09-24 | G2 records each listening socket with its scope. Only loopback-bound sockets are exempt from the contract port list | Any non-loopback socket missing from the list fails the boundary step. Changing G2 changes `gate_tree_sha256` | live-findings A; spec.md | awaiting operator review |
| 17 | `2026-09-24-irb-primary` | 2026-09-24 | No `primary` leaf is rendered on `irb0.<vlan>`. The device makes the only IPv4 address primary | Only a gateway with more than one IPv4 address per subinterface would need it. Revisit when the pinned data-server encodes an empty leaf | live-findings A; data-model.md §13; plan.md | awaiting operator review |
| 18 | `2026-09-21-spine-allow-own-as` | 2026-09-21 | Nodes that share an AS (the spines) render `as-path-options allow-own-as 1` on their underlay groups, the setting G8 qualified | Only on nodes that share an AS | live-findings B | awaiting operator review |
| 19 | `2026-09-21-unnumbered-admin-state` | 2026-09-21 (before AD-82) | The render states `ipv4/unnumbered/admin-state: disable` (the model default) on every IPv4 family it writes | One more written leaf per IPv4 subinterface, equal to the default | live-findings B; data-model.md; plan.md | awaiting operator review |
| 20 | `2026-09-21-g10-liveness` | 2026-09-21 (before AD-82) | G10's liveness case is `port mtu 10000`. r1–r8 are unchanged | On `v0.0.66` the layer's dry-run was weaker than the device for enums and union types. This was not re-observed on `v0.0.72` (qualification-record.md §What is left unqualified) | live-findings B; plan.md G10 row | awaiting operator review |
| 21 | `2026-09-21-watchlist-client` | 2026-09-21 (before AD-82) | `WatchListClient=false` on kube-controller-manager, the provider and the allocation authority | These clients use plain LIST+WATCH | live-findings B | awaiting operator review |
| 22 | `2026-09-21-schema-recycle-failed` | 2026-09-21 (before AD-82) | Provisioning deletes a `Schema` that reports `Ready=False` before the apply, and never deletes a Ready one | A failed `Schema` is re-downloaded on the next run | live-findings B | awaiting operator review |
| 23 | `2026-09-21-gnmic-otlp-strings` | 2026-09-21 | gNMIc maps the state strings the platform reads to digits and exports them as numbers | Unmapped string leaves are not exported | live-findings B | awaiting operator review |
| 24 | `2026-09-21-gate-host-ping` | 2026-09-21 | G6's sized probes run the host's iputils `ping` in the client's namespace (`nsenter -n`). A tool error is never a verdict | The host `ping` is **not pinned** in `versions.lock.yaml` `hostTooling` (NFR-003, AD-21). Under AD-82 an unpinned tool is a stop, not a build decision | live-findings B; qualification-record.md §What is left unqualified | **open — operator's decision**: pin it through `resolve_pins.sh --host-tooling`, or say otherwise |
| 25 | `2026-09-24-worker-recreate` | 2026-09-24 | The intent-tier workers use `strategy: Recreate` plus a registration watchdog | A worker is briefly absent during a roll | live-findings B | awaiting operator review |
| 26 | `2026-09-24-acl-egress-unqualified` | 2026-09-24 | `acl.egress` is published **unqualified** through the override annotations. Egress requests are refused by name (FR-097) | Egress access lists cannot be deployed on this fabric. Qualifying them needs a data-server re-pin and a gate republish | live-findings B; qualification-record.md §What is left unqualified; data-model.md `stage`; plan.md G9 | awaiting operator review |
| 27 | `2026-09-25-tier-metric-export-interval` | 2026-09-25 | Tier metrics are exported every 10 s, below the fabric exporter's 20 s expiration | Six times the tier's OTLP metric export rate | live-findings B; data-model.md §25 | awaiting operator review |
| 28 | `2026-09-25-model-call-timeout` | 2026-09-25 | `MODEL_CALL_TIMEOUT_SECONDS` defaults to 45 s with library retries off, and must be below the worker call timeout | A model call longer than 45 s fails, naming the provider (NFR-010) | live-findings C; data-model.md §25 | awaiting operator review |
| 29 | `2026-09-25-model-reasoning-effort` | 2026-09-25 | New setting `MODEL_REASONING_EFFORT`, default `low`. It is dropped for a model that takes no such parameter | Interpretation quality at `low` is what T144 measures | live-findings C; data-model.md §25 | awaiting operator review |
| 30 | `2026-09-25-acl-rule-labels` | 2026-09-25 | An unnamed rule gets a label derived from what it states. With no priority stated anywhere, rules are numbered 10, 20, … in stated order | The stated order becomes the evaluation order. The operator declines at the first confirmation if that is wrong | live-findings C; data-model.md `ACLRule` | awaiting operator review |
| 31 | `2026-09-25-port-grounding` | 2026-09-25 | A port the operator's text does not write is asked for and never supplied (FR-059) | A port written in an unknown form is asked for | live-findings C; data-model.md `Endpoint` | awaiting operator review |
| 32 | `2026-09-25-log-shape` | 2026-09-25 | Every tier log line is JSON with the correlation id. Foreign handlers are removed, and the uvicorn access log is replaced | A refused (401) request writes no access line (FR-102) | live-findings C; plan.md | awaiting operator review |
| 33 | `2026-09-25-acl-family-inference` | 2026-09-25 | An unstated family is the one the operator's prefixes (or ICMP version) state. Otherwise it is asked for, never chosen | A list with no prefix and no ICMP protocol is asked for its family | live-findings C; data-model.md `AccessList.type` | awaiting operator review |
| 34 | `2026-09-25-acl-any-placeholders` | 2026-09-25 | Port `0`/`0-0`/`0-65535`/`1-65535` and prefix `0.0.0.0/0`/`::/0` are treated as "any" (absent) | "Port 0" cannot be stated literally | live-findings C; data-model.md `ACLRule` | awaiting operator review |
| 35 | `2026-09-25-acl-default-grounding` | 2026-09-25 | A default action is kept only when the operator's words state one. Otherwise it is dropped and the platform default is reported | A default stated in an unknown form is not rendered. The confirmation still shows unmatched handling | live-findings C; data-model.md `AccessList.defaultAction` | awaiting operator review |
| 36 | `2026-09-25-acl-layer2-refusal` | 2026-09-25 | A MAC/ethertype field or Layer 2 protocol in a rule is refused with the Layer 2 out-of-scope wording (SC-027) | None | live-findings C; data-model.md `AccessList.type` | awaiting operator review |
| 37 | `2026-09-25-leftover-scan-redaction` | 2026-09-25 | `leftovers::scan` redacts every credential-bearing leaf before it writes the datastore dump to evidence. T145 is re-run | Superseded T145 runs r2/r3 keep the hash and are not covered by T147's final scan | live-findings C | awaiting operator review |

## Decisions made under the operator's delegation (AD-75…AD-81)

These were made on 2026-09-21 by Claude Code under the operator's written delegation ("do whatever do
you recommend in my behalf you are in Yolo mode"), with AD-74 before them. They are recorded in
research.md and in `live-findings.md`'s first table, and listed here so the operator sees them
together.

| AD | Decision | Status |
| --- | --- | --- |
| AD-74 | G11 failed on `kuid-server v0.0.13`. The first-party substitute (`IdentifierPool`/`IdentifierClaim`, `agentic-netops-allocation`) is adopted (`allocator-substitution.md`) | made by delegation, recorded |
| AD-75 | The schema-deviation commit is served from an in-cluster git mirror under a commit-named tag. There is no branch ref and no patched upstream | made by delegation, recorded |
| AD-76 | `inter-as-vpn` and `route-reflector client` are read from the configuration datastore. It is still a configuration-integrity check | made by delegation, recorded |
| AD-77 | SC-004's negative control is `Fabric.spec.overlay.reflectorClients: false` (observed by G8), not `interASVPN: false` | made by delegation, recorded |
| AD-78 | G6 asserts the commit-time refusal for the port maximum. The tenant boundary is the data-plane probe, and the acceptance of IRB `ip-mtu 9349` is recorded | made by delegation, recorded |
| AD-79 | A4 reads the keyed binding, and the per-subinterface entry list is an observation (then decided further by AD-82 `2026-09-21-acl-binding-state`) | made by delegation, recorded |
| AD-80 | `data-server` is re-pinned to `v0.0.72`, qualified live with `config-server v0.0.58` (qualification-record.md §Data-server re-pin) | made by delegation, recorded |
| AD-81 | The goldens freeze the G12-observed RFC 7951 module-prefixed identityrefs. `sdc-lite v0.4.0` validates a normalised copy (Open item 21) | made by delegation, recorded |

## For the operator — an observation that invites a requirement change (T155, 2026-09-28)

Open item 17 is closed: on the pinned SR Linux 25.7.1 the device **accepts** an untagged
subinterface beside tagged ones on one port (`ethernet-1/10.0` and `ethernet-1/10.3994`, committed
and read back from running; `.evidence/agentic-netops_agentic-netops-fabric/20260929T140000Z-p15-t155-probe/OI.i17.commit.json`).
The platform still **refuses** the mix (FR-034, AD-20). That is now known to be a platform rule and
not a device limit. The rule is **not** relaxed. Relaxing it would change a requirement, which is
the operator's decision (CR-007), and it would need FR-034, the webhook's one-tagging-mode rule
(T056, T061) and the mapper's refusal (T098) amended together. **Status: awaiting operator review.**
