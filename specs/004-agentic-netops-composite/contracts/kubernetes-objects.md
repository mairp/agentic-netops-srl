# Contract: Kubernetes objects and the cluster identity

**Feature**: `004-agentic-netops-composite` | **Carries**: FR-064 to FR-069, FR-075 to FR-079,
FR-101 | **Decisions**: D-22, D-33, RD-03, RD-04, AD-74

This document is the intent tier's object inventory and its **identity contract** — what exists,
who can do what, and which denials are attemptable. The identity contract is the structural half of
the safety boundary (FR-075); the behavioural half is in the requirements and the corpora.

## Namespaces

| Namespace | Holds |
|---|---|
| `agentic-netops-agents` | the intent tier's workloads |
| `agentic-netops-intent` | the `Network` objects the tier submits — the **only** namespace it may write fabric intent into |
| `agentic-netops-system` | the provider, and the authoritative copy of the fabric qualification record |
| `agentic-netops-services` | **control-plane-owned**: the `Network`s applied with cluster tooling — the shipped examples and the control-plane suites. Created with the provider (`deploy/agentic-netops/`, T042), so it exists with no tier installed; the tier holds no permission in it, its pre-flight cannot see into it while the one-owner webhook does, and the tier's removal — with or without `--remove-services` — never touches it (AD-26, AD-35) |
| `kuid-system` | the allocation authority; the tier's claims — when the lock selects kuid. On this lab, as decided (AD-74), the lock selects the first-party substitute, and this row reads `agentic-netops-allocation` (`IdentifierPool`/`IdentifierClaim`); the two never coexist (CD-03) |
| `sdc-system` | the device-configuration layer's workloads and the schema mirror (AD-75). As decided (AD-82 `2026-09-21-target-namespace`), the onboarding set, the `Target`s and the layer's copy of the device credentials Secret (`srl-credentials`) live in `agentic-netops-system` |
| `cert-manager` | a pinned prerequisite of the device-configuration layer's aggregated API server |
| `monitoring` | the observability stack. Created idempotently, with the platform's ownership label, by the lab-secret step — the first thing that writes into it (`grafana-admin` and the collector's copy of the device credentials), at `TargetsReady`, long before the stack itself is installed at `ObservabilityReady` |

The tier holds API permissions in exactly two of them: `agentic-netops-intent` and the allocation
authority's namespace (`kuid-system` under kuid; `agentic-netops-allocation` on this lab, AD-74).

## Object inventory

### Namespace `agentic-netops-agents` — the tier's workloads

| Kind | Name | Notes |
|---|---|---|
| Namespace | `agentic-netops-agents` | labelled as platform-owned and as the intent tier |
| Deployment, Service | `slim` | `46357/TCP`; image pinned by digest |
| ConfigMap | `slim-config` | gateway YAML, **TLS enabled**, not insecure |
| Secret | `slim-gateway` | generated password; no literal |
| Deployment, Service | `supervisor` | `9090`; one replica, recreate strategy |
| PersistentVolumeClaim | `supervisor-checkpoint` | the durable thread checkpointer (D-21) |
| ConfigMap | `supervisor-prompts` | system prompts and the suggested prompts, **construct vocabulary only** |
| Deployment, Service | `mapper` | `9092` |
| ConfigMap | `mapper-catalogue` | the **four constructs**, their variables and their examples |
| ConfigMap | `site-inventory` | the node map and the port map that attachment names resolve through, in the device's own `ethernet-1/N` naming; written by the provisioning script and **mounted read-only** into mapper, allocator and deployer |
| ConfigMap | `fabric-qualification` | the per-construct and per-property qualification record (FR-097), copied from `agentic-netops-system` by the tier phase of provisioning and **mounted read-only** into the same three workloads |
| Deployment, Service | `allocator` | `9091` |
| Deployment, Service | `deployer` | `9093`; **two containers**: the deployer and the translator sidecar on loopback `8090` |
| Deployment, Service | `ui` | `3000`; reached via a cluster port mapping, not an ingress controller |
| ConfigMap | `ui-env` | API base URLs pointing at cluster service DNS |
| Secret | `llm-provider` | **generated** from `AGENTIC_NETOPS_LLM_MODEL`, `AGENTIC_NETOPS_LLM_API_KEY`, `AGENTIC_NETOPS_LLM_BASE_URL` and `AGENTIC_NETOPS_LLM_GATEWAY` — keys `LLM_MODEL`, `API_KEY`, `BASE_URL` and, when the endpoint is a shared gateway, `GATEWAY` (the gateway's name). It is the provider-switch seam (NFR-008) and it carries FR-106: a declared gateway with no base URL is **refused** before any tier workload exists; re-provisioning **merges** into the existing Secret, so a run that omits the base URL preserves the stored one — clearing it takes the explicit `AGENTIC_NETOPS_LLM_BASE_URL_CLEAR=1`; provisioning prints the endpoint model calls will use, redacted of any credential the base URL embeds (FR-079); an agent whose Secret declares a gateway without a base URL refuses to start, and one whose Secret **loses** its base URL while running stops calling the model and reports it, never falling back to the library default — the Secret is mounted read-only and read on every model call. Never a whole-object replacement: that is how the predecessor silently lost its base URL |
| Deployment, Service, ConfigMap | `agent-otel-collector` | `4318` in; **one exporter out — the store — from User Story 7, where it is first installed, and the second, the forward to the fabric collector, added by User Story 12** once that collector exists, so one emission then reaches both sinks (FR-091, AD-45, AD-55). It and `clickhouse` are the first things the tier phase installs after the denial probes, waited Ready before any agent workload exists, so no audit event is emitted with nowhere to be kept (AD-45) |
| StatefulSet, Service, PVC | `clickhouse` | `8123`; the agent-analytics sink **and the audit record** (FR-078): no TTL on the trace tables, and **exported unconditionally before anything removes the store** — by `off.sh` and by `off.sh --purge-intent-tier` alike, whether or not evidence capture was asked for; a failed export stops the removal with the store intact, and only `--discard-audit-record` — printed and recorded in the run's evidence — goes past it (AD-18, AD-24). The export is newline-delimited JSON, one object per stored row, compressed, written through the evidence capture under an identifier unique to the attempt; it fails on an unqueryable store, a query error, an unwritable artefact or a short row count, and `AUDIT_EXPORT_TIMEOUT_SECONDS` (data-model.md §25) bounds it (AD-36). On every removal path that goes past the refusal the tier's request-accepting workloads are scaled down **before** the export; a re-run never rewrites an artefact — it skips where a *verified* export is found under the lab's evidence root and adds one otherwise, by the one rule of data-model.md §16; and once the store is gone the audit reconciliation reads the exported file in its file-source mode (AD-46) |
| Secret | `clickhouse-auth` | **generated** — never a default credential pair (D-23) |
| Secret | `operator-credentials` | **generated** by the provisioning script's secret step — `username` (default `operator`, overridable by `OPERATOR_USERNAME`) and an **always-generated** `password`; preserved on re-provisioning, removed by `off.sh` and, with its namespace, by the tier's removal — in both only **after** the `username`, never the `password`, has been captured into the run's evidence, because SC-042 is reconciled against the usernames the run used and must survive this Secret (data-model.md §16, AD-46); mounted **read-only into the supervisor only** (FR-102, CD-01). Lab credentials, not production-safe |
| Job | `intent-secret-generator` | reuses the existing in-cluster generator pattern |
| ServiceAccount | `intent-supervisor`, `intent-mapper`, `intent-ui` | all with **no service-account token mounted** |
| ServiceAccount | `intent-allocator` | claim-only identity |
| ServiceAccount | `intent-deployer` | the service-intent writer identity |
| NetworkPolicy | `deny-all-by-default`, `allow-egress-scoped`, `slim-ingress`, `apiserver-egress-cluster-clients` | |

Cluster-scoped, installed with the safety boundary at P1:

| Kind | Name | Notes |
|---|---|---|
| ValidatingAdmissionPolicy, ValidatingAdmissionPolicyBinding | `deny-tier-force-release` | matches `networks.fabric.agentic-netops.io` on CREATE and UPDATE; **denies** any request from `intent-deployer` or `intent-allocator` whose object sets, changes or removes the annotation `fabric.agentic-netops.io/force-release` (FR-103, CD-02). RBAC cannot tell one annotation from another; admission can. It is a tier artefact although it is cluster-scoped: it names the tier's identities and nothing else, so the tier's removal removes it with them, and the removability check looks for it by name and not only for the two namespaces (NFR-006, AD-35) |

**The two ConfigMaps are mounted, not read through the API.** `site-inventory` and
`fabric-qualification` reach the workloads as read-only volumes, and **no RBAC rule grants the tier
any verb on ConfigMaps anywhere** — which is why "ConfigMaps" stays in the deliberately-absent list
below. The authoritative qualification record lives at
`agentic-netops-system/fabric-qualification`, written by the capability gate whether or not the tier
is installed; the tier-namespace copy is made by the tier phase of provisioning.

### Namespace `agentic-netops-intent` — the tier's submitted intent

| Kind | Name | Notes |
|---|---|---|
| Namespace | `agentic-netops-intent` | the **only** namespace the tier may write fabric intent into. It is the tier's: created by the tier phase and removed with the tier — but **not together with the `Network`s in it** unless the removal was given `--remove-services`. Without it the removal's first list — a read that decides only whether to go on — names them and the removal stops non-zero, having changed nothing; with it the tier's request-accepting workloads are scaled down first, the **authoritative** list of the `Network`s to delete is taken **after** that scale-down, the audit record exported, the listed `Network`s deleted, their finalizers waited on for a bounded time and never force-released, and the namespace goes only once a re-list returns empty. Without the flag and with nothing to refuse over, the scale-down still precedes the export, and a list taken after it that is not empty falls back to the refusal, having deleted and exported nothing (NFR-006, AD-24, AD-26, AD-35, AD-46). `Network`s applied with cluster tooling belong in the control-plane-owned `agentic-netops-services`, which the provider's install creates, no tier identity can write to, and the tier's removal never touches; the cross-object admission rules see both namespaces alike |
| Role, RoleBinding | `intent-writer` | `networks.fabric.agentic-netops.io` and Events — nothing else |
| Network | *(created at runtime)* | `fabric.agentic-netops.io/v1alpha1`, labelled with the correlation identifier |

### Namespace `kuid-system` — the allocation authority, borrowed narrowly

As decided (AD-74), this lab runs the first-party substitute: the same Role and RoleBinding
(`kuid-claimer`, same verbs, no `update`, no `patch`) sit in `agentic-netops-allocation` on
`identifierclaims.fabric.agentic-netops.io` only (`deploy/rbac/claims/first-party/role.yaml`). The
kuid form below is what the lock selects under `allocationAuthority.kind: kuid`.

| Kind | Name | Notes |
|---|---|---|
| Role, RoleBinding | `kuid-claimer` | **claim objects only**, in exactly two served groups (D-22, RD-09): `vlanclaims.vlan.be.kuid.dev` and `genidclaims.genid.be.kuid.dev`; `get, list, watch, create, delete`; **no `update`, no `patch`** |

### The monitoring namespace

| Kind | Name | Notes |
|---|---|---|
| Secret | `grafana-admin` | **generated** by the lab secret step with the device credentials — administrator username and an always-generated password, no literal in any manifest, anonymous access disabled; removed by `off.sh` (FR-096, FR-019). Written whether or not the tier is installed |
| ConfigMap | `grafana-dashboards-agents` | the intent-tier dashboard (FR-095), mounted by a **reversible two-line patch** applied by the tier flag and reverted by the purge flag (R-19) |

## Identity contract

The tier has exactly **two** cluster API identities. Stated positively, the writer identity may:

- create, read, update, patch and delete `networks.fabric.agentic-netops.io` in the intent
  namespace;
- create Events in the intent namespace — which is how it **mirrors** the audit events it decides
  itself (submission, removal, out-of-band detection). The supervisor decides confirmations,
  declines and refusals and holds no cluster permission, so it mirrors none: the audit **record** is
  the trace-borne event in the agent-analytics store, never a Kubernetes Event (FR-078, AD-18).

The allocator identity may:

- get, list, watch, create and delete `vlanclaims.vlan.be.kuid.dev` and
  `genidclaims.genid.be.kuid.dev` in `kuid-system` — or, on this lab (AD-74),
  `identifierclaims.fabric.agentic-netops.io` in `agentic-netops-allocation`.

**And nothing decides *when* it may delete one.** Whether a claim is still provisional turns on
whether its `Network` exists, and the allocator identity holds no verb on `networks` anywhere. The
**deployer** — which already reads `networks` in the intent namespace — is what determines it and
names the releasable correlation identifiers; the allocator deletes what it is told to. No identity
gains a verb for this, so the two verb sets above remain the complete ones (FR-075, FR-109,
AD-32).

**That is the complete list.** Deliberately absent from every rule: Secrets, **ConfigMaps**, Pods,
`pods/exec`, Nodes, the device-configuration groups `inv.sdcio.dev` and `config.sdcio.dev`, the
`fabrics.fabric.agentic-netops.io` design object, every resource in `agentic-netops-system`, the
`ipam.be.kuid.dev` and `as.be.kuid.dev` groups, the allocation indices themselves, and
`update`/`patch` on claims.

*The writer Role once also granted `srv6services`. That grant is removed with the API it named, and
**GAP-5 is closed by narrowing**: the tier's writer identity now grants exactly one resource
(RD-04).*

Stated as denials — each one attemptable against the relevant identity, which is what SC-029
requires:

| Attempt | Expected | Why it is denied |
|---|---|---|
| read Secrets in any namespace | `no` | no Role grants Secrets anywhere |
| read the mounted ConfigMaps through the API | `no` | no Role grants ConfigMaps anywhere; the tier reads them from a read-only volume, never from the API server |
| update a `Network` in `agentic-netops-system` | `no` | the writer Role is namespaced to the intent namespace |
| read a `Network` as the **allocator** identity, in any namespace | `no` | no rule mentions `networks` for that identity; the deployer decides what is releasable and the allocator deletes what it is told to (FR-109, AD-32) |
| read a `Network` in `agentic-netops-services` as the **deployer** identity | `no` | the writer Role is namespaced to the intent namespace; a holder there is refused by the one-owner webhook instead |
| create or read a `Fabric` | `no` | no rule mentions it; the fabric design is the provider's |
| create a `Config` or `ConfigSet` (`config.sdcio.dev`) | `no` | no rule mentions the device-configuration groups |
| read a `Target` or a `Schema` (`inv.sdcio.dev`) | `no` | same |
| create `pods/exec` | `no` | no rule mentions Pods |
| update or patch a claim | `no` | `update` and `patch` deliberately withheld |
| set `fabric.agentic-netops.io/force-release` on a `Network` as the writer identity | **denied at admission** | the `deny-tier-force-release` policy; the identity that reads operator text cannot release an identifier a device may still carry (FR-103) |
| read `operator-credentials` through the API as any tier identity | `no` | no Role grants Secrets anywhere; the supervisor reads it from a read-only volume and holds no token |
| claim from `ipam.be.kuid.dev` or `as.be.kuid.dev` | `no` | those belong to the `Fabric` reconciler, not the tier |
| TCP connect from a tier pod to **`172.25.25.0/24:57400`** (gNMI over TLS) | **timeout** | the scoped egress policy denies the whole management CIDR |
| TCP connect to **`172.25.25.0/24:57401`** (plaintext gNMI) | **timeout** | the same policy — an unauthenticated plaintext management port would otherwise bypass the entire boundary |
| TCP connect to **`172.25.25.0/24:22`** (SSH) | **timeout** | the same policy |
| TCP connect to **`172.25.25.0/24:80`** and **`:443`** (JSON-RPC) | **timeout** | the same policy |
| TCP connect to **`172.25.25.0/24:830`** (NETCONF) | **timeout** | the same policy |
| TCP connect to **`172.25.25.0/24:50052`**, **`:57410`** and **`:57411`** (the vendor automation ports the image reserves whether or not that product is used) | **timeout** | the same policy; a port that is open and unused is still a door |
| UDP send to **`172.25.25.0/24:161`** (SNMP) | **no reply; zero packets counted** | the same policy — but see the UDP note below: this row is *recorded* by the probe and *asserted* by SC-028's counter |
| dial any management port on any device by address | timeout | the same policy; **and no credential exists either way** |

**The probe dials every management port the device image is documented to expose, not only the one
the platform uses. This table is the one authoritative list of that port set**; every other surface —
[quickstart.md](../quickstart.md) §15, [plan.md](../plan.md) P1, `tasks.md` T066 and
[platform-coupling.md](../platform-coupling.md) PC-S-03 — cites it rather than restating it; the
one runnable copy, the loop in quickstart §15, is diffed against this sentence by
`tests/unit/boundary/port_list_test.sh` (T066), so a copy cannot drift silently. Taken
from [evidence/01-lab-platform.md](../evidence/01-lab-platform.md) §4.2, the lab image exposes
**TCP 22, 80, 443, 830, 50052, 57400, 57401, 57410 and 57411, and UDP 161**. The platform speaks gNMI
over TLS on `57400` and nothing else; **every other port must be denied**, and a denial that covered
only the port in use would leave nine open doors.

**Two honesty notes on that list.** *(a)* **UDP has no timeout signal.** A dropped datagram is
indistinguishable from a silent server, so the probe sends to `161`, records that no reply came, and
leaves the assertion to SC-028's per-source packet counter, which counts packets toward the
management CIDR whatever the protocol. The UDP row is recorded evidence, not an observed refusal, and
must be read as such. *(b)* **The list is documentation, not an observation of the pinned image.**
§4.2 was probed on a release later than the pin, and the same report's CPM-ACL baseline also records
an allow rule for Telnet/23 that §4.2 shows no listener for. Capability-gate item **G2** (version and
platform identity) therefore records the ports the pinned image actually listens on, and a listening
port G2 finds that this list does not carry fails the boundary step rather than being discovered
later.

**This is the FR-075 guardrail.** The constraint is not "the agent declines"; it is that **neither
identity can express a device action**. An agent fully compromised by prompt injection (R-20) still
cannot open a device session, because the API server and the network plugin refuse before any agent
logic runs. The behavioural refusal (FR-076) is the layer that usually catches it; this is the
layer that holds when that one fails.

The management CIDR defaults to **`172.25.25.0/24`** and is configurable (`MGMT_CIDR`); the device
addresses are `.11`, `.12` (spines) and `.21`, `.22` (leaves); the port set is the ten above. Those
are concrete values that move with the platform:
[platform-coupling.md](../platform-coupling.md) PC-A-06. **The denial itself must never weaken —
and it must continue to cover every port, not merely the one in use.**

**Why the tier does not submit into the control plane's namespace**: with no rule there, an
authorization check as the tier's identity returns `no` for every verb on control-plane-owned
resources — a one-command proof rather than an argument — and an agent that somehow constructed
such a request is refused by the API server (D-33).

## Resource stamping contract (FR-101)

**One owner per key, disjoint key sets, a fixed emission order.** Three actors write metadata across
this platform; **only two of them touch the `Network`.**

| Actor | Writes | Onto |
|---|---|---|
| the translator | the translation and provenance keys — the construct, the arrival vocabulary, the translator version | the `Network` |
| the intent tier | the correlation label, the tier label, the audit annotations and the **submitted-spec hash** (FR-105) | the `Network` |
| the provider | its source identity, observed generation, render hash, compatibility set and mapping version | the **`Config` objects it generates** — never the `Network` |

Emission order is fixed: translator keys first, tier keys second. **Neither actor writes the
other's keys**, and the provider writes none of them.

The tier's own set, on every object it creates — the `Network` and every claim:

```yaml
labels:
  agentic-netops.io/correlation-id: <32 hex trace id>    # selectable; the join and rollback key
  agentic-netops.io/tier: intent
annotations:
  agentic-netops.io/intent-thread-id: <uuid>
  agentic-netops.io/intent-principal: <authenticated operator username>   # FR-102; never caller-asserted
  agentic-netops.io/intent-submitted-at: <RFC3339>
  agentic-netops.io/intent-submitted-spec-sha256: <64 hex>   # Network only; FR-105; written once, last
```

The hash is the SHA-256 of the canonical JSON of `spec` **as the server-side dry-run returned it**.
The dry-run carries every other key; the apply is the dry-run object plus this one annotation, and a
unit test asserts they differ in that key only. Nothing else writes the key and nothing rewrites it.
One annotation is **not** the tier's and is denied to it: `fabric.agentic-netops.io/force-release`
is an operator break-glass read by the provider (FR-103).

Metadata only: no schema, controller or reconciliation contract changes (NFR-007). *(GAP-3 is
closed: the union is specified here rather than left to collide.)*

## Submission contract (FR-065, FR-066, FR-067)

1. **Pre-flight** — scan the intent namespace for an access-list binding conflict on the exclusivity
   key *(node, port, subinterface, direction, address family)*, and for a second owner of any
   (node, port, VLAN) attachment; refuse naming the incumbent service if there is one (FR-043,
   FR-034). A service carrying a deletion timestamp is still an incumbent, and the refusal says so.
   **The pre-flight scans the intent namespace only** — it is the early, better-worded copy of the
   cross-object rules, never the arbiter. A holder in the control-plane-owned
   `agentic-netops-services` is invisible to it and is refused by the one-owner webhook at step 4,
   which sees both namespaces alike ([crd-api.md](./crd-api.md)); the bundle aborts and step 6
   rolls back, so the outcome is the same and only the wording is poorer. Both VLANs in such a
   conflict are **named** ones: with the bands disjoint an allocated VLAN can never equal a named
   one, so the pre-flight has no allocated-VLAN collision to look for (AD-33).
2. **Translate** — POST to the loopback sidecar; see [translator-api.md](./translator-api.md).
3. **Stamp** — the labels and annotations above, in the fixed order (FR-101).
4. **Dry run** — server-side dry-run every object; **any rejection aborts the whole bundle** with
   the rejecting object named. Nothing is mutated. **A dry-run that fails because the admission
   webhook could not be reached is not a rejection.** The webhook fails closed
   ([crd-api.md](./crd-api.md), AD-52), so while the provider that serves it is down the API server
   refuses every `Network` create and update, a dry-run included. That answer names no rule, no
   holder and no valid alternative, and the deployer MUST NOT report it as a refusal of the request:
   it is a failure of the **cluster API dependency** (NFR-010), named as the admission webhook being
   unreachable, retried under the worker-call retry rule of [../data-model.md](../data-model.md) §25
   and then reported as that dependency's failure with the thread left resumable. Nothing was
   applied, so there is nothing to roll back, and the request's claims are still provisional and are
   treated as any unsubmitted request's are (FR-056, FR-066).
5. **Apply** — deterministic order, **with the provider's finalizer already set** on every
   `Network` in the bundle. The deployer needs no new verb for this — a finalizer is part of
   `metadata` and it already holds `create`, `update` and `patch` on `networks` here — and it closes
   the window in which an object exists with no finalizer, before the provider's first reconcile,
   in which a deletion would take the object away and leave the tier's claims with no release owner
   (FR-109, AD-32). A `Network` applied with cluster tooling takes the finalizer from the provider
   instead, and the window there is the operator's own.
6. **Roll back on failure** — delete everything matching the correlation label and report the
   rolled-back set. The label makes the set exact and re-runnable, **including after a supervisor
   restart**, because the label survives in the cluster when in-process state does not. An object
   that reached step 5 is already finalizer-bound, so its deletion blocks until the provider has
   read the removal back and released what it adopted; the rollback **never deletes a claim of an
   object it applied** — the deployer names as releasable only the correlation identifiers whose
   `Network` does not exist (FR-103, AD-32), which is what stops a rollback freeing an identifier a
   device may still carry.
7. **Watch** — each object to Ready, terminal failure, or the convergence timeout (150 s by
   default, [../data-model.md](../data-model.md) §25); report which of the three occurred.
   `Ready=Unknown` is none of them and keeps the watch open (FR-067, AD-40); `Ready=False/Deleting`
   — the object deleted under the watch — is a terminal failure naming the deletion, reported as
   deleted outside the tier when the tier recorded no removal of it (FR-105, AD-63). Every
   `progress` chunk the watch produces carries the condition's status string and its reason,
   unaltered ([supervisor-http.md](./supervisor-http.md), AD-62).

**Removal** (FR-069, AD-63) is steps of its own, after both confirmations: re-read the live object
(FR-105); **delete** the `Network` — and no claim, which the provider's finalizer releases (AD-16);
**watch until the object no longer exists**, under the same convergence timeout. Gone within the
bound is the removal reported complete. Still present at the bound, the deployer reports the
removal **in progress**, with what the object's `Deleting` condition names as outstanding, and
returns — it retries nothing, force-releases nothing (it cannot: admission denies it the
annotation), and the finalizer completes the removal unaided (FR-103). An accepted delete is never
reported as a completed removal.

**Step 4 is now a real gate.** `Network` is a first-party CRD with a **structural OpenAPI schema and
no `x-kubernetes-preserve-unknown-fields` on `spec`**, plus admission rules, so a server-side
dry-run rejects a malformed or self-contradictory object at the API server rather than accepting it
and failing later. That is one of the two things "dry run" means on this platform; the other is the
device-configuration layer's schema validation of the **rendered device configuration**, which
happens after the `Network` is accepted and is not this step. The API server cannot validate a
rendered device configuration, and this contract never presents it as doing so.

A failed rollback is reported as failed with the surviving objects named, **never as success**
(R-21).

## Health probes

| Workload | Liveness | Readiness |
|---|---|---|
| supervisor | `GET /health` | `GET /v1/health` |
| mapper / allocator / deployer | `GET /v1/health` | same |
| transport gateway | TCP `46357` | TCP `46357` |

The supervisor's split is deliberate: a worker outage must make the supervisor **NotReady**, never
**restarted**, or the thread state SC-024 requires would be lost on every worker blip.

## Telemetry objects

Agents emit **once** to the tier collector, which is the single fan-out point with two exporters:
one to the analytics store and one forwarding to the fabric collector. Every tier metric carries the
platform-prefixed agent prefix chosen so it passes the fabric collector's **existing** filter
unmodified — which is what makes "no control-plane file changes" true (D-37). A conformance test
asserts exactly one exporter endpoint is configured per agent process (R-24).
