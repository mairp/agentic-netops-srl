# Specification Quality Checklist: Agentic NetOps on Nokia SR Linux — Composite Platform

**Purpose**: Validate the consolidated, retargeted specification before planning proceeds
**Created**: 2026-09-20
**Feature**: [spec.md](../spec.md)

**Note**: This checklist is merged from the three source requirements checklists and extended for
the SR Linux retarget. It is a reviewer-owned requirements-quality review artifact.

**Marker semantics**: A checked marker means a reviewer has determined the requirements-quality criterion is
satisfied. It does **not** mean implementation work is complete. **Every item below is `[ ]`**: no
reviewer has reviewed this composite, and marking an inherited checked marker forward would assert a review
that did not happen. The three source checklists carry their own checked marks against their own
documents; those marks are evidence about those documents, not about this one. The retarget did not
inherit a mark either — a review of a SONiC document is not a review of an SR Linux one.

---

## Content quality

- [ ] CHK001 No implementation detail leaks into the requirements — languages, frameworks and
      product names appear in the plan and the contracts, not in the FR, NFR or SC text
- [ ] CHK002 Focused on operator value and system behaviour rather than on mechanism
- [ ] CHK003 All mandatory template sections are present and filled
- [ ] CHK004 The document is readable by someone who has not opened 001, 002 or 003

## Identity and scope

- [ ] CHK005 Scope distinguishes replacing a logical role and service intent from installing the
      network operating system on arbitrary hardware
- [ ] CHK006 All network nodes are SR Linux nodes in containerlab; Linux is limited to endpoints
      and tooling
- [ ] CHK007 Proprietary controller, vendor fabric-automation product, device-package and runtime
      dependencies are explicitly excluded, and the exclusion is CI-enforced
- [ ] CHK008 Production ASIC equivalence and live automatic cutover are not implied by the lab, and
      the containerized dataplane's packet-rate ceiling is stated as a limit tests must respect
- [ ] CHK009 The document describes the system on Nokia SR Linux and does not half-describe another
      platform; every inherited platform binding is inventoried **and given a disposition and a
      resolution** in `platform-coupling.md`, and the couplings SR Linux newly introduces are
      inventoried there too

## Consolidation integrity *(new to this composite)*

- [ ] CHK010 Every composite FR, NFR, SC, CR, user story, decision and risk appears in the forward
      traceability table — including the identifiers the retarget added and the ones it retired
- [ ] CHK011 Every source FR, NFR, SC, user story, decision and risk appears in the reverse table,
      including those merged away, superseded, or retired by the retarget
- [ ] CHK012 No source requirement vanished silently: every reverse row resolves to `carried`,
      `merged` or `retired-by-retarget`, `dropped-with-reason` is used nowhere, and every
      `retired-by-retarget` row names the retiring decision and where the obligation went
- [ ] CHK013 Every superseded claim appears **only** in its superseding form, and each supersession
      is recorded with its citation
- [ ] CHK014 No source-qualified identifier form survives in live requirement text — only in
      citations, `traceability.md` and `platform-coupling.md`
- [ ] CHK015 Identifiers are flat and continuous, grouped by concern, with lettered sub-ids folded
      and the fold recorded; **no identifier was renumbered by either pass**, and no retired number
      is reused
- [ ] CHK016 The safety-boundary requirements are contiguous and unbroken
- [ ] CHK017 Scope-boundary prose from the sources is recorded as history in §Provenance, not
      carried forward as a live constraint
- [ ] CHK018 The removability property survives the merge and the retarget as a requirement, not as
      an artefact of two documents having been separate

## Honesty *(Principle I applied to this document about itself)*

- [ ] CHK019 Status is `Draft`, matching all three sources
- [ ] CHK020 No task is marked complete; no `tasks.md` is produced
- [ ] CHK021 Each disputed approval is carried **with** its contradiction, not alone
- [ ] CHK022 The absent-runtime caveat is stated once, plainly, and everything resting on it is
      qualified by it; every number taken from research is phrased as measured in research and
      re-observed at the first delivery phase, not as observed on the pinned release
- [ ] CHK023 The constitution gate is re-evaluated for a **greenfield** repository rather than
      inheriting the predecessor's two failures: no deployment exists here to fail, the principles
      are recorded as pass-by-obligation, and the predecessor's defects are stated as the reason
      NFR-003 and NFR-013 exist — neither laundered into a pass nor waived as an exception
- [ ] CHK024 Where a source specified a design the sources themselves record as **not** what was
      built, the divergence is recorded as history **and** answered by a named requirement, rather
      than carried forward as an unresolved pair

## Requirement completeness

- [ ] CHK025 No `[NEEDS CLARIFICATION]` marker remains
- [ ] CHK026 Requirements are testable and unambiguous; each states a single obligation
- [ ] CHK027 Absolute constraints are marked as such rather than reading as defaults
- [ ] CHK028 Success criteria are measurable, and each names a verification method
- [ ] CHK029 Success criteria are technology-agnostic
- [ ] CHK030 All acceptance scenarios are defined for every live user story
- [ ] CHK031 Edge cases are identified across the fabric, the constructs, the intent tier and
      observability
- [ ] CHK032 Scope is clearly bounded, with out-of-scope items stated — including the deferred
      scope, which names what would reopen it
- [ ] CHK033 Dependencies and assumptions are identified, each stating its consequence
- [ ] CHK034 Every `[GAP]` the merge recorded resolves to exactly one carrying requirement or to a
      named deferral, and no gap is closed by prose alone

## Architecture quality

- [ ] CHK035 Kubernetes reconciliation is the orchestration workflow; no second workflow engine
- [ ] CHK036 The reused upstream device-configuration layer owns device transactions and drift, and
      the reused upstream allocation authority owns identifier allocation; the first-party fabric
      API owns only the fabric design and the service intent those two cannot express
- [ ] CHK037 The platform adds one narrow provider rather than a second orchestrator, and a "gap
      controller" beside an upstream renderer is rejected by name as a second translation path
- [ ] CHK038 The first-party API fills only what no maintained upstream API can express, and
      delegates topology allocation, identifier allocation and device transactions to the layers it
      reuses
- [ ] CHK039 One device transaction and drift layer
- [ ] CHK040 Ownership boundaries prevent two reconcilers from managing the same path, and two
      configuration objects that could touch one device leaf may not share a priority
- [ ] CHK041 Direct reconciliation is the first slice; review workflows are clearly later
- [ ] CHK042 Upstream APIs are reused rather than duplicated, and **no first-party Kind occupies an
      upstream project's API group**
- [ ] CHK043 The intent tier is a layer **above** the declarative boundary, never beside it, and
      the dependency arrow never points back

## Upstream capability and version realism

- [ ] CHK044 The dependency state of every upstream project is stated as it was found, not as it
      was hoped: the device-configuration layer active and exercised against this device release in
      its own CI; the allocation authority and the upstream fabric control plane **dormant**, with
      their last release dates given
- [ ] CHK045 Version drift between published tutorial artefacts and current upstream objects is
      identified, and no requirement rests on a tutorial's field names
- [ ] CHK046 One complete pinned upstream release or commit is required for each reused project,
      installed from that project's own artefacts
- [ ] CHK047 Device image, YANG model tag, schema definition, schema deviation patch,
      device-configuration release, allocation release, containerlab, collector and provider
      mapping versions form **one** qualified compatibility set, and the set's weakest member — the
      one that caps the device release — is named
- [ ] CHK048 There is one lab profile and one device image; the capability gate is what qualifies
      it, and there is no second profile to fall back to when an item fails
- [ ] CHK049 Acceptance cannot skip, mock or substitute host forwarding for device behaviour: the
      pinned profile must pass the complete gate, and a construct or property the gate does not
      qualify is refused by name rather than attempted
- [ ] CHK050 Floating versions, mutable tags, branch references and placeholder or synthetic
      digests are forbidden wherever a reference can appear, the pin check resolves every digest
      against its registry, and the predecessor's failure to meet this is recorded as the reason
      the rule is stated this strongly
## Construct vocabulary

- [ ] CHK051 The construct set is closed at four and nothing else is advertised as a type
- [ ] CHK052 Name resolution is case-, hyphen-, underscore- and space-insensitive
- [ ] CHK053 Each construct states what it MUST provision **and what it must not** — no VNI or
      route targets for a local bridge domain, no overlay identifier for a filter
- [ ] CHK054 Symmetric IRB is expressed as composition, not as a fifth type name
- [ ] CHK055 A variable belonging to another construct is refused naming both the property and the
      construct that carries it
- [ ] CHK056 Retired service names remain accepted as **input aliases only**, and appear in output
      solely as provenance
- [ ] CHK057 Every constraint the fabric enforced per service type is enforced per construct, with
      the cause stated in construct terms
- [ ] CHK058 A service that converged before the vocabulary changed is reported by its construct
      with its stored record untouched

## Access lists

- [ ] CHK059 An access list is expressible both as a service and as a property of another service
- [ ] CHK060 Binding is to attachment subinterfaces only; an operator names node, port and
      optionally VLAN, and a request for a network-instance, IRB or fabric-wide binding is refused
      saying so
- [ ] CHK061 A stage, an address family and at least one rule are required
- [ ] CHK062 Duplicate priorities, duplicate names, a claim on the reserved default-action
      position, a cross-family prefix, an L4 port on a protocol other than TCP or UDP, a filter name
      the device reserves for its own filters, and an out-of-range value are each refused with the
      offending rule named
- [ ] CHK063 The evaluation order and the usable priority range are stated to the operator at the
      first confirmation; a declared default action is rendered explicitly at the reserved **last
      position in the evaluation order**; and when none is declared the confirmation states that
      the platform will accept unmatched traffic
- [ ] CHK064 Convergence requires both the written configuration and the device's own programmed
      state for **this** filter, keyed by filter name, address family and entry; an unobserved
      property is never reported as converged; and readiness never depends on passing traffic
- [ ] CHK065 A subinterface already bound in the same direction for the same address family refuses
      the second binding, naming the incumbent, and nothing is displaced; a service being removed
      still holds its bindings until it is gone
- [ ] CHK066 What the platform cannot express is refused **by name** rather than rendered as a row
      that never matches, and what is excluded by scope rather than by capability says so
- [ ] CHK067 The predecessor's switch-wide applied-side check is recorded as a defect, the
      requirement that prevents it is named, and the platform's own stock filter entries are
      documented as the hazard that would recreate it

## Service translation and migration safety

- [ ] CHK068 The migration alias catalogue is explicit and expressed in construct terms
- [ ] CHK069 Limited equivalence requires opt-in and is not claimed as full parity
- [ ] CHK070 Traffic engineering, pseudowire OAM, multicast, complex QoS, service chaining and
      unknown properties are rejected or deferred
- [ ] CHK071 Translation is all-or-nothing before any downstream mutation
- [ ] CHK072 Identifier, reference and collision validation is specified
- [ ] CHK073 Raw device CLI is not an accepted translation input
- [ ] CHK074 Source-scoped constraints stay scoped to their source vocabulary
- [ ] CHK075 Exactly one translation implementation exists, and the access-list render is a field
      on the same object rather than a second path

## Intent tier

- [ ] CHK076 The pipeline stages each have a single responsibility and a schema-validated output
- [ ] CHK077 Two explicit human confirmations are required and a one-shot request cannot provision
- [ ] CHK078 Declining releases every provisionally claimed identifier and leaves the fabric
      unchanged — **including when the construct claimed nothing**
- [ ] CHK079 Under-specified requests ask for exactly the missing detail rather than defaulting a
      service-defining value
- [ ] CHK080 Every allocated identifier comes from the existing allocation authority per the
      construct's claim profile, and every identifier the platform derives instead is shown in the
      assignment exactly as it will be rendered
- [ ] CHK081 Submission is atomic, dry-run-gated and rollback-enumerable, with the convergence
      outcome reported as one of three; and "dry-run" names a check that can actually fail, not one
      the API server cannot perform
- [ ] CHK082 Workers are independently addressable, runtime-discoverable, timeout- and
      retry-bounded, with unreachable distinguished from failed
- [ ] CHK083 The workflow status vocabulary is closed and the unknown status is never a success

## Safety boundary

- [ ] CHK084 The no-device-session rule is absolute and is stated once, at its strongest
- [ ] CHK085 It is enforced **structurally** — an identity that cannot express the action — and not
      only behaviourally
- [ ] CHK086 Every denial is attemptable and enumerated, so the claim is provable rather than
      argued, and the enumeration covers **every** device management port the lab image exposes,
      including the plaintext one
- [ ] CHK087 User text and worker text are treated as data, with the injected-instruction case
      producing a byte-identical proposal
- [ ] CHK088 Every confirmation, decline, submission and refusal is auditable with principal and
      correlation identifier
- [ ] CHK089 Credentials and secrets are redacted from every prompt, log, trace and transcript, and
      no device credential appears as a literal anywhere
- [ ] CHK090 The delivery sequence builds and proves this boundary **before any agent is deployed**

## Lab, lifecycle and placement

- [ ] CHK091 One pinned cluster, declaratively configured, is the sole application runtime
- [ ] CHK092 One provisioning path and one shutdown path cover the whole platform, tier included
- [ ] CHK093 Both are idempotent, partial-state tolerant and ownership-checked
- [ ] CHK094 Containerlab is limited to network and endpoint nodes
- [ ] CHK095 A dedicated management network connects cluster nodes to the lab; its address space is
      configurable and is checked against every existing Docker network, the pod network and the
      service network before anything is created
- [ ] CHK096 All configuration, Secrets, RBAC, state, dashboards and alerts are Kubernetes
      resources
- [ ] CHK097 Standalone, Compose and host-side deployment of platform applications is forbidden
      **without exception** — no component outside the cluster may read or write device
      configuration — and the predecessor's host-side executor is recorded as the defect this rules
      out rather than as a carried exception

## Observability

- [ ] CHK098 The telemetry pipeline, the metrics store and the dashboards are all required
- [ ] CHK099 The metrics store is correctly identified as storage; the collector is a pipeline
- [ ] CHK100 Durable logs and traces require an explicit later addition
- [ ] CHK101 One device collector, with overlapping subscription-based ingestion disabled for the
      same series, and the device management server's session limit sized for both clients together
- [ ] CHK102 One emission per agent activity, fanned out to two sinks, never two instrumentations
- [ ] CHK103 A versioned topology asset is generated from the lab inventory, in the same step as the
      collector's target list, and its identifiers are verified against live metric queries
- [ ] CHK104 Both a physical view and an EVPN service-path view are specified, the join between
      topology assets and metrics is an explicitly named label set, and the visualization reference
      introduces no runtime dependency
- [ ] CHK105 A telemetry outage is observable but cannot control or block network configuration
- [ ] CHK106 The correlation identifier joins agent activity, reconciliation and device telemetry
      in both directions with no timestamp correlation

## Security and operations

- [ ] CHK107 TLS, Secrets, least-privilege RBAC, redaction and lab-credential limitations are
      covered
- [ ] CHK108 Privileged containers and host runtime access are documented trust boundaries, and no
      hypervisor or nested-virtualization requirement is implied
- [ ] CHK109 Break-glass finalizer behaviour and orphan risk are included, including the deletion
      ordering a bound filter imposes on the object that owns its subinterface
- [ ] CHK110 No credential literal appears in any manifest, and CI enforces it

## Requirement quality and traceability

- [ ] CHK111 User stories are independently testable and prioritized
- [ ] CHK112 Functional and non-functional requirements are unambiguous
- [ ] CHK113 Success criteria map to quickstart evidence
- [ ] CHK114 The spec, plan, data model, contracts and quickstart use one set of component names
      and one ownership model
- [ ] CHK115 Research distinguishes verified upstream capability from proposed platform work, and
      every rejected alternative is preserved
- [ ] CHK116 The constitution gate evaluates all six principles by name, with a verdict and a
      reason each

## SR Linux retarget integrity *(new to the second pass)*

These are the checks a **retarget** needs and a single-platform specification does not. They ask
whether the platform move is complete, honest and self-consistent — not whether it was a good idea.

- [ ] CHK117 Every row of `platform-coupling.md` carries a disposition (`deleted`, `rewritten`,
      `replaced`, `unchanged` or `resolved`) and, where it is not `unchanged`, a concrete resolution
      naming the RD decision, the requirements that carry it and the evidence section that proves it
- [ ] CHK118 No predecessor-platform term survives in live requirement text. Run:
      `grep -rniE 'sonic|redis|config_db|asic_db|\bgcu\b|\bsai\b|\bfrr\b|fabric-executor|fabricplan|docker exec|Ethernet[0-9]|\bkvm\b|nested virtualiz|kubenet|NetworkDevice|172\.31\.' spec.md plan.md research.md data-model.md quickstart.md contracts/`
      and confirm every remaining hit is a provenance, history or superseded-decision note. The
      resolution record (`platform-coupling.md`), the traceability record (`traceability.md`) and
      `evidence/` are the only files where such terms are expected
- [ ] CHK119 Every retired identifier resolves: it keeps its number, carries a one-line tombstone in
      `spec.md`, keeps its source mapping in the forward table, is listed by name in
      `traceability.md` §Nothing dropped, and names where its obligation went
- [ ] CHK120 Each of the six decisions the merge left open is decided, and each decision names the
      requirements that carry it; none is answered by prose that no requirement enforces
- [ ] CHK121 Each of the six gaps the merge recorded is closed by exactly one carrying requirement
      or by a named deferral, and the gap-to-requirement mapping is stated in one place
- [ ] CHK122 Every RD decision records decision, rationale, **evidence citation** and alternatives
      rejected; no RD rests on assertion alone, and where an evidence report disagrees with the
      decision the disagreement is stated rather than smoothed over
- [ ] CHK123 No digest, version, YANG path or upstream behaviour is invented. Every digest that
      appears anywhere in this folder also appears in `evidence/` or in the retarget decision
      record; where a digest is required but not known, the text says it is pinned at the first
      delivery phase rather than showing a placeholder
- [ ] CHK124 The capability gate covers every construct **and every gated property** the
      specification depends on, its result is published per construct and per property where the
      tier can read it, and an unqualified construct or property is refused at interpretation by
      name (FR-097)
- [ ] CHK125 Every applied-side read-back path is **keyed** to this service's own objects
      (FR-100, FR-042); no readiness or acceptance check counts objects fabric-wide or
      device-wide; and each check has a recorded negative control showing it fails on a stock
      fabric before its pass counts (NFR-013, SC-040)
- [ ] CHK126 Wherever an access list is confirmed to an operator, the evaluation order, the usable
      priority range and what happens to unmatched traffic are all stated — in the requirement, in
      the contract, in the data model and in the quickstart alike, with no surface omitting one
- [ ] CHK127 The MTU numbers are identical in `spec.md`, `plan.md`, `data-model.md`,
      `quickstart.md` and the constitution: port maximum, fabric link MTU, underlay IP MTU, tenant
      MTU over VXLAN, the two acceptance probe payloads, and the endpoint interface MTU
- [ ] CHK128 The management CIDR default, the device and endpoint addresses, and the device port
      list are identical in `spec.md`, `plan.md`, `quickstart.md` and the Kubernetes-objects
      contract, and the denial enumeration names the same ports the lab image is documented to open
- [ ] CHK129 The compatibility set is identical, part for part, in `plan.md`, `research.md` and
      `contracts/crd-api.md`, with no part present in one and absent from another
- [ ] CHK130 The constitution version cited is **v1.1.0** everywhere it is cited, and no file cites
      the pre-amendment version or its removed known-limitation clause
- [ ] CHK131 Node names, node count, hardware types, containerlab kind and interface naming are
      identical everywhere they appear — the topology file, the site inventory, example attachment
      strings, gNMI paths, metric labels and the suggested prompts
- [ ] CHK132 The couplings the new platform introduces are inventoried, not only the ones it
      resolved, so the next platform move starts from a complete seam
- [ ] CHK133 Nothing in this pass claims observation: every number taken from a research report is
      attributed to that report and marked for re-observation, and no gate, probe or counter is
      reported as having passed
- [ ] CHK134 Every dormant upstream dependency is qualified at the first delivery phase, carries a
      named first-party fallback behind the same contract, and the choice between them is made
      explicitly at that phase rather than by drift
- [ ] CHK135 The two construct names that match the device's own network-instance types are
      **required** to match, asserted in CI against the pinned device model, and the other two are
      documented as operator vocabulary alongside the device objects they render

## Readiness result

**Not assessed.** No reviewer has run this checklist against this document. The composite is
`Draft`; it describes a greenfield repository in which nothing is built, no cluster exists and no
fabric has been launched; its inherited acceptance record carries three disputed approvals and a
fourth contradiction found by the retarget research. It is ready to be **reviewed**; it is not
recorded as having passed anything, and the retarget did not make it any more verified than the
merge did — it made it implementable, which is a different property.

## Notes

- Items CHK010 to CHK024 exist only in this composite. They are the checks a merge needs and a
  single-feature specification does not: traceability in both directions, supersession resolution,
  identifier discipline, and the honesty obligations that keep an inherited approval from being
  laundered by the act of consolidation.
- Items CHK117 to CHK133 exist only because of the second pass. They are the checks a **retarget**
  needs: that every coupling was resolved rather than dropped, that no term of the old platform
  survives where it would mislead, that every retired number still resolves, that the decisions and
  gaps the merge left open are carried by requirements rather than by prose, and that the concrete
  values a platform move introduces — versions, digests, ports, addresses, MTUs, interface names —
  agree across every file that repeats them. A retarget fails most often by being *partially*
  applied, and these are the questions that detect that.
- Three findings recorded by the source checklists are carried forward and remain true here:
  cross-feature identifier collision (resolved by renumbering, with both directions traceable);
  the polyglot repository as an accepted cost; and the model-quality boundary, where interpretation
  accuracy is measured but the safety properties are specified not to depend on it.
- Two scope decisions the source checklists resolved as documented assumptions remain assumptions
  here: retired service names stay accepted as input aliases, and symmetric IRB is composition
  rather than a fifth type.
- One assumption the source checklists carried has been **withdrawn** rather than reaffirmed: that
  proving dataplane enforcement of an access list is out of scope. On this platform it is
  demonstrable, so it is demonstrated in acceptance — while readiness still never depends on
  traffic. CHK064 and the enforcement criterion are deliberately separate for that reason.
- Five defaults the retarget chose where the evidence supported more than one answer are flagged in
  `spec.md` §Clarification candidates. They are live requirements as written; this checklist does
  not treat a flagged default as an open question, and a reviewer who disagrees with one should
  raise it as a clarification rather than as a checklist failure.
