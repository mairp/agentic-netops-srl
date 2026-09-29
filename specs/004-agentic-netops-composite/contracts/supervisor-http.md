# Contract: supervisor HTTP surface

**Feature**: `004-agentic-netops-composite` | **Carries**: FR-050 to FR-057, FR-074, FR-080 to
FR-084, **FR-102** | **Decisions**: D-24, D-34, **CD-01**

Exactly five routes. **There is no WebSocket route**: the README's WebSocket path describes a
removed interface, and it is not implemented, not probed and not documented here (D-34).

Base: `http://supervisor.agentic-netops-agents.svc:9090`

---

## Authentication (FR-102, SC-042)

**Every route that can reach the pipeline requires an authenticated operator.** The mechanism is
HTTP Basic, verified by the supervisor against the generated Secret `operator-credentials`, which it
reads from a read-only volume ([kubernetes-objects.md](./kubernetes-objects.md)).

| Route | Credential |
|---|---|
| `POST /agent/prompt/stream` | **required** |
| `GET /suggested-prompts` | **required** |
| `GET /transport/config` | **required** |
| `GET /health`, `GET /v1/health` | none — probe routes; they create no thread, call no model and claim nothing, and a probe credential would be a credential literal in a manifest. This is the one exception FR-102 names |

```text
no or wrong credential  ─►  401  WWW-Authenticate: Basic realm="agentic-netops"
                            body: {"type":"error","status":"FAILED","reason":"authentication required"}
```

Rules:

- The refusal is decided **before a thread identifier is minted**: no thread, no model call, no
  claim, no `AuditEvent`. It produces a structured log line and increments
  `agentic_netops_agent_auth_refusals_total` ([../data-model.md](../data-model.md) §21).
- **The principal is the authenticated username and nothing else.** The request body has no
  `principal` field; the schema is strict, and a request that carries one is refused `400` naming
  the field — a client that believes it is asserting an identity is told it is not.
- A thread continued under a different credential records that credential's username on the
  decision it carries; it does not inherit the first one.
- Comparison is constant-time and a failed attempt costs a fixed delay.
- These are **lab credentials over loopback HTTP and are not production-safe** (FR-019). The route
  count stays at five: there is no login route, no session and no token.

---

## `POST /agent/prompt/stream`

The only operator entrypoint. Streams **newline-delimited JSON** — one object per line,
`Content-Type: application/x-ndjson`.

**Request**

```json
{ "prompt": "Extend vlan 100 as a mac-vrf across leaf01 ethernet-1/1 and leaf02 ethernet-1/1 for tenant blue",
  "thread_id": "3f2b…" }
```

`thread_id` is optional on the first message and required to continue a thread (FR-052). There is
**no `principal` field**: the principal comes from the `Authorization` header (see Authentication).

**Response chunks** — every chunk carries the correlation identifier and a status:

```json
{"type":"status","correlation_id":"4bf9…4736","status":"RECEIVED_REQUEST","stage":"supervisor"}
{"type":"stage","stage":"mapper","status":"MAPPED","payload":{"…Interpretation…":null}}
{"type":"confirmation_request","stage":"mapper","prompt":"Confirm this interpretation?","refusable":true}
{"type":"stage","stage":"allocator","status":"ALLOCATED","payload":{"…NormalizedServiceIntent…":null}}
{"type":"confirmation_request","stage":"allocator","prompt":"Deploy this service?","refusable":true}
{"type":"stage","stage":"deployer","status":"PROVISIONING","resources":[{"kind":"Network","name":"migr-svc1"}]}
{"type":"progress","status":"VERIFIED","resource":"Network/migr-svc1","ready":"True"}
{"type":"final","status":"COMPLETED","correlation_id":"4bf9…4736"}
```

`ready` on a `progress` chunk is the `Ready` condition's **status string**, as the cluster reports
it, and takes three values — `"True"`, `"False"`, `"Unknown"` — never a two-valued boolean:
`"Unknown"` is what a re-verification that
could not run leaves (`Ready=Unknown/VerificationFailed`, AD-40), it is never rendered as success
(FR-054, FR-067), and a `"False"` carries the condition's `reason` beside it (`"reason":"Deleting"`
for a service being removed, AD-53). The example's `"ready":"True"` is the converged case only. A dry-run
or apply that fails because the cluster API — the admission webhook included (AD-52) — cannot be
reached is reported as an `error` chunk of the dependency-failure class naming the cluster API
(NFR-010), exactly as an unavailable worker is (FR-074), and the thread stays resumable.

The final chunk may also carry a redacted operator-facing message. The surface renders that
message rather than exposing an internal status token as the answer.

Failure chunk (FR-082) — always names the responsible stage:

```json
{"type":"error","stage":"allocator","status":"FAILED",
 "reason":"validation failed: endpoints[1].vlan is required for mac-vrf",
 "correlation_id":"4bf9…4736"}
```

**Rules**

- `status` is drawn **only** from the closed workflow-status set (D-24).
- Confirmation is a subsequent POST on the same thread. **No submission occurs without the second
  confirmation** (FR-055), enforced in the submission stage and not only in routing.
- A bounded exit — the iteration cap or the deadline — emits a final failed chunk with a
  bounded-exit reason. **Never a hang** (FR-053). Defaults: 3 iterations per request turn and a
  300 s deadline with operator confirmation time excluded, both configuration
  ([../data-model.md](../data-model.md) §25).
- Every payload shown to the operator names the **construct**, never a retired service name
  (FR-026).
- **A status request takes no confirmation; a removal takes both** (FR-069): a status request is
  informational (FR-057) — authenticated like every route, traced, and changing nothing — while a
  removal is a change and runs the two confirmations of creation.
- **A removal ends when the object is gone, or says what it is still waiting for** (FR-069, AD-63).
  After the second confirmation the deployer deletes the `Network` and watches until it no longer
  exists, under the convergence timeout of a creation ([../data-model.md](../data-model.md) §25).
  The stream carries `PROVISIONING` while it watches — never `CONFIGURED` or `VERIFIED`, which no
  removal can mean — and one of two endings:

  ```json
  {"type":"progress","status":"PROVISIONING","resource":"Network/migr-svc1","ready":"False","reason":"Deleting"}
  {"type":"final","status":"COMPLETED","correlation_id":"4bf9…4736"}
  ```

  when the object is observed gone within the bound; and, when it is still present at the bound,

  ```json
  {"type":"progress","status":"PROVISIONING","resource":"Network/migr-svc1","ready":"False","reason":"Deleting"}
  {"type":"final","status":"PROVISIONING","correlation_id":"4bf9…4736",
   "message":"removal in progress: waiting on leaf02 (TargetUnreachable); it completes when the target returns"}
  ```

  — a `final` chunk whose status is neither `COMPLETED` nor `FAILED` nor `STATUS_UNKNOWN`, because
  the removal neither finished, failed nor was lost from view. Its message repeats what the
  object's `Deleting` condition names as outstanding and never offers the force-release as
  something the tier can do (FR-103). The surface renders it as in progress — not as success and
  not as an error. A later status request answers from the live object. A **creation** watch that
  sees `"ready":"False","reason":"Deleting"` ends with an `error` chunk of the deployer stage naming
  the deletion, carrying `"out_of_band":"deleted"` when the tier recorded no removal of that object
  (FR-067, FR-105).
- **A status or removal answer is built from the live object** (FR-105). When the object's `spec` no
  longer matches the submitted-spec hash, or the object is gone and the tier did not remove it, the
  answer says so first, in words — *modified outside the intent tier* or *deleted outside the intent
  tier* — and then reports the live state. The chunk carries it as data too:

  ```json
  {"type":"stage","stage":"deployer","status":"VERIFIED","out_of_band":"modified",
   "resource":"Network/migr-svc1","payload":{"…live state…":null}}
  ```

  `out_of_band` is `"modified"`, `"deleted"` or absent. The tier writes nothing in response, and a
  removal asked of a modified service is not executed by the turn that detects it.

## `GET /health`

Trivial liveness, `{"status":"ok"}`. **Wired to the liveness probe.** It must not touch the
transport, so a worker outage never restarts the supervisor into amnesia.

## `GET /v1/health`

Deep check: builds a transport client and probes each worker. **Wired to the readiness probe.**
Names the specific unavailable worker (FR-074):

```json
{"status":"degraded","transport":"SLIM","endpoint":"http://slim.agentic-netops-agents.svc:46357",
 "workers":{"mapper":"ok","allocator":"ok","deployer":"unreachable"}}
```

`200` when every worker answers, `503` otherwise. The liveness/readiness split is what lets the
supervisor stay alive with thread state intact while reporting NotReady (SC-024).

## `GET /transport/config`

```json
{"transport":"SLIM","endpoint":"http://slim.agentic-netops-agents.svc:46357"}
```

The endpoint is **`:46357`** and comes from the long variable name (D-27).

## `GET /suggested-prompts`

**SUPERSEDED-RESOLVED.** This route previously served the four service-provider service names. It
serves the **four constructs** and nothing else (FR-084, superseding
`002:contracts/supervisor-http.md:88-91`). The served set covers, at minimum:

| # | Shape | Construct |
|---|---|---|
| 1 | a local broadcast domain on one attachment | `vlan` |
| 2 | a VLAN extended across two leaves | `mac-vrf` |
| 3 | a routed instance carrying a prefix at one attachment | `ip-vrf` |
| 4 | the gateway composition | `mac-vrf` + anycast gateway |
| 5 | a standalone filter on an attachment another service already created | `acl` |
| 6 | a filter attached to a service in the same request | any construct + `acl` |

Every prompt's nodes and ports **must resolve against the site's real inventory** (FR-084, R-30) and
are written in the device's own naming — `leaf01`, `ethernet-1/1` — never a name this platform
invented. A unit test asserts it, and the quickstart validates it against the live port map. No
retired service name appears in any served prompt, and no prompt offers a construct or a property
the fabric qualification record does not show as qualified (FR-097).

---

## Worker HTTP surfaces

Each worker exposes its agent-to-agent application plus a deep-health route.

| Worker | Port |
|---|---|
| supervisor | 9090 |
| allocator | 9091 |
| mapper | 9092 |
| deployer | 9093 |

The deployer pod additionally runs the translator sidecar on loopback `8090`, with **no Service and
no network-policy allowance** — see [translator-api.md](./translator-api.md).
