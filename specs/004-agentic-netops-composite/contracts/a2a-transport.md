# Contract: agent-to-agent transport, discovery and payload carriage

**Feature**: `004-agentic-netops-composite` | **Carries**: FR-070 to FR-074, FR-065 |
**Decisions**: D-27, D-28, D-29

## Transport

| Setting | Value |
|---|---|
| Default message transport | `SLIM` |
| Transport endpoint variable | **`TRANSPORT_SERVER_ENDPOINT`** |
| Endpoint | `http://slim.agentic-netops-agents.svc:46357` |
| Gateway image | `ghcr.io/agntcy/slim:0.6.1`, pinned by digest |
| Data-plane port | **`46357`** |
| Controller port | `46358`, **not exposed** |

**The variable name is the long one and the port is 46357.** The project README gives a short
variable name and a different port; nothing listens on that port and nothing reads that name. The
supervisor's call helpers hard-require this transport and raise rather than falling back, so this
is not a soft default (D-27).

**Authentication (FR-072)**: the gateway runs TLS with client-certificate verification against a CA
generated in-cluster, and its password comes from a generated Secret. An unauthenticated
registration attempt must be refused; the refusal raises the transport authentication error from
the corrected exceptions module — the orphaned, misspelled module the fidelity analysis found, now
spelled correctly and **actually wired in** (D-23). This replaces the subject's insecure-TLS
posture. The qualification gate and the named fallback are in [research.md](../research.md) D-28;
the fallback is an **accepted risk with a stated production delta**, never a silent downgrade
(R-14).

A NetworkPolicy admits the transport port only from pods labelled as the intent tier.

## Discovery (FR-071)

Each worker publishes an agent card. The card's identifier must be a routable
`org/namespace/local_name`, because the registration and addressing topic is derived from it —
used by the server to register and by the client to address.

| Worker | Card identifier | Skill |
|---|---|---|
| mapper | `devnet/provisioning/network-mapping` | map a network request |
| allocator | `devnet/provisioning/network-allocator` | allocate a network service |
| deployer | `devnet/provisioning/network-deployer` | deploy a network service |

The supervisor resolves a capability to a topic through the card **at call time**. It holds no
hardcoded worker list, so adding or replacing a worker changes no supervisor code.

## Call semantics (FR-073, FR-074)

A per-call timeout, a bounded retry with exponential backoff, and a reported distinction between
the two failure classes — because they mean different things to the operator. Defaults: 60 s per
call (210 s for the deployer, which contains the convergence watch), 2 retries with backoff from
1 s, and only the *unreachable* class is ever retried ([../data-model.md](../data-model.md) §25):

| Class | Condition | Reported as |
|---|---|---|
| unreachable | topic unresolved, transport error, or timeout with no response | `"worker unreachable: mapper"` — retryable, **the thread stays resumable** |
| failed | the worker answered with an error or an out-of-contract payload | `"worker failed: mapper — <reason>"` — terminal for the stage |

## Payload carriage (FR-065, D-29)

Each stage message carries **two parts**:

1. a text part — the human-readable summary, plus the compatibility marker;
2. a **data part** — the structured object. **Authoritative.**

The pinned agent-to-agent SDK already models a part as text, file or data, so this needs no
protocol change.

| Stage | Marker (compatibility only) | Data-part schema |
|---|---|---|
| mapper → supervisor | the mapped-JSON comment marker | [`interpretation.schema.json`](./interpretation.schema.json) |
| allocator → supervisor | the deployment-JSON comment marker | [`normalized-service-intent.schema.json`](./normalized-service-intent.schema.json) |

**Receiver rule.** Read the data part when present; otherwise parse the marker. **Either way,
validate against the model before any use**, and treat a validation failure as a terminal stage
failure that submits nothing. String-splitting a comment marker out of model prose cannot satisfy
FR-065 — a truncated or duplicated marker yields either a parse crash or a silently partial object.
That is why the data part exists.

The markers are retained only so the existing chat rendering path works unchanged. **They are never
the validation boundary.**
