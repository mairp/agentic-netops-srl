# Tutorial — first bring-up of Agentic NetOps on SR Linux

## Runbook standard

| | |
|---|---|
| **Audience** | An operator bringing the platform up for the first time on a clean lab host, with shell access and permission to run privileged Docker containers. |
| **Scope** | One walk-through, start to end: provision the environment with the intent tier, confirm every agent is healthy, provision one construct through the tier and one with `kubectl`, then tear everything down. After it, a reference part states the key facts of every topic the four documents share. |
| **What it assumes** | A Linux x86-64 host that meets [Host requirements](#19-host-requirements), the host tools `versions.lock.yaml` checks, this repository checked out, and a model-provider credential. Nothing in this file reports an observed result: every **Expected** line is what the specification requires, and a result is only a result once its evidence is captured under `.evidence/` (constitution Principle I). |
| **The four documents** | `TUTORIAL.md` (this file) — the first bring-up walk-through. [`docs/operator-guide.md`](docs/operator-guide.md) — asking for services through the tier and reading what it reports. [`docs/operations-guide.md`](docs/operations-guide.md) — running the platform day to day: secrets, bounds, drift, audit, observability, host. [`docs/runbook.md`](docs/runbook.md) — incident procedures, in full. |

Every procedure below has the same shape: **When** · **Before you start** · **Steps** · **Expected** ·
**If it fails** · **Evidence**. The vocabulary is the four constructs — `vlan`, `mac-vrf`, `ip-vrf`,
`acl` — and nothing else. The site's access ports are `leaf01 ethernet-1/1` and `leaf02 ethernet-1/1`
(`examples/fabric/default-fabric.yaml`).

---

## Part 1 — The walk-through

### Step 1 — Bring-up with the intent tier

**When** — on a clean host, once; running it again is safe (it converges and recreates nothing).

**Before you start**
- The host meets [Host requirements](#19-host-requirements); `make verify-pins` passes.
- A free management `/24` (default `172.25.25.0/24`; the preflight refuses an overlap and names the colliding network).
- The model-provider inputs are exported in this shell (they become the `llm-provider` Secret, never a manifest):

```bash
export AGENTIC_NETOPS_LLM_MODEL="openai/gpt-5"        # the model-name prefix selects the provider
export AGENTIC_NETOPS_LLM_API_KEY="<your key>"
# only for a shared gateway — a gateway without a base URL is refused before the tier is created:
# export AGENTIC_NETOPS_LLM_GATEWAY="<gateway name>"
# export AGENTIC_NETOPS_LLM_BASE_URL="https://<gateway>/v1"
```

**Steps**

```bash
MGMT_CIDR=172.25.25.0/24 ./scripts/provision.sh --cluster-name agentic-netops --with-intent-tier
```

**Expected** — the script logs each phase in this order and waits for each with a bounded timeout:
`NetworkReady` → `ClusterReady` → `LabReady` → `AppsReady` → `TargetsReady` → `GateReady` →
`FabricReady` → `ObservabilityReady` → `IntentTierReady`, and exits 0. Near the end it prints the
two loopback URLs — the supervisor on `http://127.0.0.1:19090` (NodePort 30990) and the chat surface
on `http://127.0.0.1:13000` (NodePort 30300) — and the endpoint model calls will use, redacted.

**If it fails** — the last line names the phase: `provisioning stopped at <Phase>`. Go to
[Per-stage failure diagnosis](#3-per-stage-failure-diagnosis) for that phase. Fix the cause and run the same
command again; it resumes by converging, never by recreating the cluster.

**Evidence** — each run writes under `.evidence/agentic-netops_agentic-netops-fabric/<UTC run id>/`
(the gate record, the operator username capture — never the password —, image IDs). Check it with
`make verify-evidence`.

### Step 2 — Confirm the agents are healthy

**When** — right after Step 1, and whenever the chat surface misbehaves.

**Before you start** — Step 1 exited 0.

**Steps**

```bash
kubectl --context kind-agentic-netops -n agentic-netops-agents get deploy,sts,po
curl -s http://127.0.0.1:19090/health              # liveness, no credential
curl -s http://127.0.0.1:19090/v1/health | jq      # readiness: every worker probed, no credential

# everything else needs the generated operator login (lab credentials, never invented)
OP_USER=$(kubectl -n agentic-netops-agents get secret operator-credentials -o jsonpath='{.data.username}' | base64 -d)
OP_PASS=$(kubectl -n agentic-netops-agents get secret operator-credentials -o jsonpath='{.data.password}' | base64 -d)
AUTH=(-u "$OP_USER:$OP_PASS")
curl -s "${AUTH[@]}" http://127.0.0.1:19090/transport/config
```

**Expected** — every Deployment and the `clickhouse` StatefulSet ready; `/health` answers
`{"status":"ok"}`; `/v1/health` answers `200` with `"status":"ok"` and `mapper`, `allocator` and
`deployer` all `ok`; `/transport/config` names the transport endpoint on port `46357`.

**If it fails** — `/v1/health` answers `503` naming the worker that is down:
`kubectl -n agentic-netops-agents get po` and that worker's logs. `401` on `/transport/config` means
the credential was read wrongly or rotated since — read it again.

**Evidence** — the tier phase recorded the operator username (`operator-username-<attempt>`) in the run's evidence directory.

### Step 3 — Provision a construct through the tier

**When** — to ask for a service in plain language; this is the operator's normal path.

**Before you start** — Step 2 passed; `AUTH` is set in the shell. The prompt names only a
construct and ports the site has.

**Steps** — in the chat surface at `http://127.0.0.1:13000` (log in with the operator credentials),
or against the stream:

```bash
curl -sN "${AUTH[@]}" http://127.0.0.1:19090/agent/prompt/stream \
  -H 'content-type: application/json' \
  -d '{"prompt":"Extend vlan 100 as a mac-vrf across leaf01 ethernet-1/1 and leaf02 ethernet-1/1 for tenant blue"}'
# read "thread_id" and "correlation_id" from the chunks; confirm the interpretation on the same thread:
curl -sN "${AUTH[@]}" http://127.0.0.1:19090/agent/prompt/stream \
  -H 'content-type: application/json' -d '{"prompt":"yes, confirm","thread_id":"<thread_id>"}'
# the second confirmation, after ALLOCATED shows the claimed VNI and the derived values:
curl -sN "${AUTH[@]}" http://127.0.0.1:19090/agent/prompt/stream \
  -H 'content-type: application/json' -d '{"prompt":"yes, deploy it","thread_id":"<thread_id>"}'

CID=<correlation_id>
kubectl -n agentic-netops-intent get networks.fabric.agentic-netops.io -l agentic-netops.io/correlation-id=$CID
```

**Expected** — `MAPPED` with an interpretation and a first confirmation request; `ALLOCATED` with
the claimed L2VNI, VLAN 100 carried as named and claiming nothing (naming band), the route target,
EVI and subinterface `ethernet-1/1.100`, and a second confirmation request; then `PROVISIONING` →
`VERIFIED` → `COMPLETED`. The `Network` in `agentic-netops-intent` reports `Ready=True` only after
the two-sided read-back passed. The detail of every chunk is in
[`docs/operator-guide.md`](docs/operator-guide.md).

**If it fails** — an `error` chunk always names the stage (`mapper`, `allocator`, `deployer`) and
the reason. A refusal creates nothing. `STATUS_UNKNOWN` is never success — ask for the service's
status, which is read from the live object.

**Evidence** — the confirmations, the submission and any refusal are audit events in the analytics
store (see [Audit record](#10-audit-record)); the trace id is the correlation id.

### Step 4 — Provision a construct with kubectl

**When** — to declare a service yourself, without the tier; the control plane does not need the tier.

**Before you start** — `FabricReady` was reached. The example lives in `agentic-netops-services`,
the namespace for `Network`s applied with cluster tooling — never the tier's.

**Steps**

```bash
kubectl apply -f examples/constructs/vlan.yaml          # Network lab-vlan: vlan 110 on leaf01 ethernet-1/1
kubectl -n agentic-netops-services wait networks.fabric.agentic-netops.io/lab-vlan \
  --for=condition=Ready --timeout=300s
kubectl -n agentic-netops-services get networks.fabric.agentic-netops.io lab-vlan \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status}/{.reason}{"\n"}{end}'
```

**Expected** — `Ready=True` after the read-back; on leaf01 a bridged instance `vlan-lab-vlan` with
subinterface `ethernet-1/1.110` (see `examples/constructs/README.md`). A `vlan` has no VNI and VLAN
110 is from the naming band, so nothing is claimed. A `mac-vrf` applied this way
(`examples/constructs/macvrf.yaml`) gets its VNI claim from the provider — see
[Network applied with kubectl](#17-network-applied-with-kubectl--vni-claims-and-allocationconflict).

**If it fails** — `Accepted=False` names the rule (owner, tagging mode, band, allocation). A webhook
call error means the provider is not Ready (the webhook fails closed): check
`kubectl -n agentic-netops-system get pods`.

**Evidence** — `make verify-services` is the recorded check (with its negative control first) once
every example is applied with `kubectl apply -f examples/constructs/`.

### Step 5 — Tear down

**When** — when you are done with the lab.

**Before you start** — nothing is required: the full teardown needs no `--remove-services`, and it
exports the audit record first.

**Steps**

```bash
./scripts/off.sh --cluster-name agentic-netops
```

**Expected** — phases `TeardownPlan` → `TeardownAuditExport` → `TeardownLab` → `TeardownSecrets` →
`TeardownAllocation` → `TeardownCluster` → `TeardownNetwork` → `Absent`, exit 0. A second run is a
no-op. Container images and everything under `.evidence/` are kept.

**If it fails** — a present-but-unowned target refuses the whole run with nothing deleted; a failed
audit export stops with the store intact (see [Teardown](#2-teardown)).

**Evidence** — the audit export `audit-export-<attempt>.ndjson.gz` and the usernames record land in
the run's directory under `.evidence/agentic-netops_agentic-netops-fabric/`.

---

## Part 2 — Reference: the nineteen topics

Every topic below is shared by the four documents. The full incident procedures are in
[`docs/runbook.md`](docs/runbook.md); the facts stated here are the ones you need on the day.

### 1. Bring-up

- One command, one lifecycle: `MGMT_CIDR=<cidr> ./scripts/provision.sh --cluster-name agentic-netops [--with-intent-tier]`.
  There is no flag that skips, reorders or selects phases, no device-profile flag and no allocator flag.
- Phases, each waited with a bounded timeout (`PROVISION_WAIT_TIMEOUT` 300 s; `PROVISION_TARGETS_TIMEOUT` 600 s;
  `PROVISION_FABRIC_TIMEOUT` 900 s): **NetworkReady** (pins and host preflight, owned management network) →
  **ClusterReady** (pinned Kind cluster, nodes attached) → **LabReady** (containerlab topology, gNMI port 57400 accepts) →
  **AppsReady** (cert-manager → the allocation authority the lock file selects → gate item G11 → the device-configuration
  layer → the SR Linux provider with `DRIFT_POLICY=revertive`) → **TargetsReady** (lab Secrets, onboarding, four Targets Ready) →
  **GateReady** (capability gate record) → **FabricReady** (`examples/fabric/` applied, `fabric01` Ready) →
  **ObservabilityReady** (monitoring stack, re-check against the gate's observation, then the ten alert rules) →
  **IntentTierReady**, only with `--with-intent-tier` (extended preflight, safety boundary and denial probes before any
  agent exists, analytics store, agents, chat surface).
- Idempotent: a re-run never recreates the cluster and issues no unchanged device configuration.

### 2. Teardown

- `./scripts/off.sh [--cluster-name <name>] [--preserve-evidence] [--discard-audit-record]`.
- Order: ownership plan (read-only; anything present but not owned by this cluster refuses the whole run) → optional
  evidence capture → **audit-record export whenever the analytics store exists** → lab → generated Secrets (the operator
  username captured first) → `agentic-netops-allocation` → Kind cluster → owned management network.
- **The evidence root `.evidence/<cluster>_<lab>/` is never deleted**, with or without `--preserve-evidence`; that flag only
  *adds* a capture of the state about to be removed. Container images are never removed.
- A failed export stops the teardown with the store intact; `--discard-audit-record` goes past it, and its use is printed and recorded.
- Exit 0 torn down or nothing to do; 1 refused or a step failed (named); 2 usage.

### 3. Per-stage failure diagnosis

The script names the phase it stopped at. What to look at, per phase (the full symptom table is
the specification's quickstart §"Diagnosing a failure", reproduced in [`docs/runbook.md`](docs/runbook.md)):

| Phase | Look at |
|---|---|
| `NetworkReady` | The preflight line: pins (`make verify-pins`), SSSE3 / kernel ≥ 4.10, vCPU/RAM shortfall, or a `MGMT_CIDR` overlap naming the colliding Docker network — re-run with a free `/24`. |
| `ClusterReady` | `kind get clusters`; `docker network inspect agentic-netops-mgmt` — every Kind node attached. |
| `LabReady` | `docker ps --filter label=containerlab=agentic-netops-fabric`; the device image digest from `versions.lock.yaml`. |
| `AppsReady` | A stop naming **G11** means the allocation authority failed its claim round-trip: read the G11 evidence (`g11-observations.json`), fix the authority or record the decision in `docs/decisions/allocator-substitution.md`; the script never picks another allocator. Otherwise `kubectl -n agentic-netops-system get pods` (provider) and `kubectl -n sdc-system get pods`. |
| `TargetsReady` | `kubectl -n agentic-netops-system get targets.config.sdcio.dev`: TLS, credentials, or the device's shared gRPC session limit. |
| `GateReady` | The gate record under the run's evidence directory; a failed item is recorded and the construct or property it gates is refused by name — never skipped. |
| `FabricReady` | `kubectl -n agentic-netops-system get fabrics.fabric.agentic-netops.io fabric01 -o yaml` — the condition names the missing invariant; `make show-bgp`, `make show-evpn`. |
| `ObservabilityReady` | The phase names an absent series or a differing setting; `make wait-observability`. The alert rules are not loaded until the re-check passes. |
| `IntentTierReady` | The extended preflight names a shortfall before anything is created; a denial probe not observed aborts before any agent exists; then `kubectl -n agentic-netops-agents get po` and `/v1/health`. |

### 4. Force-release procedure

**When** — only when a `Network` deletion is blocked with `Deleting=True/TargetUnreachable` on a
device that **will not return** (decommissioned). If the device will come back, restore its
management reachability instead: the deletion completes by itself, and nothing on that path has a deadline.

**Before you start** — confirm the state and the device named:
`kubectl -n <ns> get networks.fabric.agentic-netops.io <name> -o jsonpath='{.status.conditions[?(@.type=="Deleting")]}'`.
You act as a cluster operator, not through the tier: both tier identities are denied this
annotation by the admission policy `deny-tier-force-release`.

**Steps**

```bash
# <ns> is agentic-netops-services (applied with kubectl) or agentic-netops-intent (submitted by the tier)
kubectl -n <ns> annotate networks.fabric.agentic-netops.io <name> \
  fabric.agentic-netops.io/force-release="leaf02 decommissioned, ticket <id>"
kubectl -n agentic-netops-system get fabrics.fabric.agentic-netops.io fabric01 -o jsonpath='{.status.findings}' | jq
```

**Expected** — a `Warning` Event `ForceReleased`; the object gone and its claims released; a finding
appended to `Fabric.status.findings[]` naming the service, the device, every identifier released and
the object names it had rendered, stating that the device **may still carry stale configuration**.
While the device is away the `Fabric` is `Ready=Unknown` with `Degraded=True/VerificationFailed`; once it
returns with the finding open, `Degraded=True/StaleConfigurationPossible` beside `Ready=True`. The
finding clears only after a clean scheduled read-back shows every named object absent.

**If it fails** — an empty reason is refused (`Warning` Event `ForceReleaseRefused`). The annotation
is **honoured only on a deleting object blocked on `TargetUnreachable`**; set on a live service, or on
one waiting on the allocation authority, it is ignored with an Event — it is never a way to delete.
Never remove the finalizer by hand: that records nothing and orphans claims and configuration.

**Evidence** — the finding on the `Fabric` (it outlives the `Network`) and the Event. Full
procedure: [`docs/runbook.md`](docs/runbook.md).

### 5. Operator credentials

- Secret `operator-credentials` in `agentic-netops-agents`, keys `username` (default `operator`,
  `OPERATOR_USERNAME` at provisioning overrides it) and `password`, **always generated** — never
  taken from a flag, a file or the environment (`OPERATOR_PASSWORD` is ignored with a warning).
- Read it: `kubectl -n agentic-netops-agents get secret operator-credentials -o jsonpath='{.data.username}' | base64 -d`
  (and `{.data.password}` the same way) — into the environment, never pasted into a file or a log.
- Rotate it: an existing password is preserved on re-provisioning, so empty it and let the generator write a new one:

```bash
kubectl -n agentic-netops-agents patch secret operator-credentials --type merge -p '{"data":{"password":""}}'
CLUSTER_NAME=agentic-netops bash scripts/lib/intent_secrets.sh operator-credentials   # or re-run provision.sh --with-intent-tier
```

  The supervisor reads the Secret from a read-only volume and **re-reads it without a restart**;
  events recorded under the old credential stay valid.
- These are **lab credentials over loopback HTTP Basic — not production-safe**. `off.sh` removes
  the Secret only after its username (never the password) is captured into evidence.

### 6. Model-provider Secret

- Secret `llm-provider` in `agentic-netops-agents`, from `AGENTIC_NETOPS_LLM_MODEL`, `AGENTIC_NETOPS_LLM_API_KEY`,
  `AGENTIC_NETOPS_LLM_BASE_URL` and `AGENTIC_NETOPS_LLM_GATEWAY` (keys `LLM_MODEL`, `API_KEY`, `BASE_URL`, `GATEWAY`).
- **Declaring a gateway requires a base URL**: a gateway with no base URL (given or stored) is refused before anything
  of the tier is written, so the library's default endpoint is never used silently.
- **The base URL is preserved on re-provisioning** because the Secret is written by a merge of only the keys the run
  sets; an unset input keeps its stored value.
- Change it with a merge patch, then restart the agents:

```bash
kubectl -n agentic-netops-agents patch secret llm-provider --type merge \
  -p '{"stringData":{"LLM_MODEL":"anthropic/claude-opus-5","API_KEY":"<key>"}}'
kubectl -n agentic-netops-agents rollout restart deploy/supervisor deploy/mapper deploy/allocator deploy/deployer
```

- Clear the base URL only with `AGENTIC_NETOPS_LLM_BASE_URL_CLEAR=1` on a provisioning run (together with a new base URL
  it is refused as contradictory).
- **Never a whole-object replace** — `kubectl replace` or `apply` of a full Secret drops every key it omits, the base URL
  included. The endpoint is printed redacted (credentials in userinfo or query parameters become `***`) — FR-106.

### 7. lastVerifiedTime and the stalled re-verification alert

- `status.lastVerifiedTime` on every `Fabric` and `Network` is the last scheduled re-verification that **ran** — it
  advances on every pass that completed its read-back, **whatever it found** (a `Ready=False` pass still ran).
- A pass that **cannot run** (target unreachable, read timed out) sets `Ready=Unknown/VerificationFailed` and
  `Degraded=True/VerificationFailed` naming the target, and `lastVerifiedTime` stops. `Unknown` is never success and never failure.
- The alert `ReverificationStalled` fires on the age of the last pass:
  `time() - reverify_last_success_timestamp_seconds` greater than one re-verification interval plus one reconciliation
  interval (5 min + 15 s at the defaults) — whatever `Ready` says (FR-107).
- Read it: `kubectl -n agentic-netops-services get networks.fabric.agentic-netops.io lab-vlan -o jsonpath='{.status.lastVerifiedTime}'`.

### 8. Default bounds

Every bound has one default (data-model.md §25) and is an environment variable on its owner; a
start-up check asserts `convergence < deployer call < request deadline`.

| Bound | Default | Owner · variable |
|---|---|---|
| Reconciliation interval | 15 s | provider · `RECONCILE_INTERVAL` |
| Transient-error backoff | from 250 ms, full jitter, cap 10 s, 6 attempts | provider · `RETRY_BACKOFF_BASE`, `RETRY_BACKOFF_CAP`, `RETRY_MAX_ATTEMPTS` |
| Re-verification interval | 5 min, **floor 30 s** (shorter or unparsable refuses the provider's start) | provider · `REVERIFY_INTERVAL` |
| Orchestration iteration limit | 3 per request turn | supervisor · `SUPERVISOR_MAX_ITERATIONS` |
| Request deadline | 300 s, confirmation time excluded | supervisor · `SUPERVISOR_REQUEST_DEADLINE_SECONDS` |
| Worker call timeout | 60 s | supervisor · `WORKER_CALL_TIMEOUT_SECONDS` |
| Deployer call timeout | 210 s | supervisor · `DEPLOYER_CALL_TIMEOUT_SECONDS` |
| Worker call retries | 2 (1 s, then 2 s; only "unreachable") | supervisor · `WORKER_CALL_RETRIES` |
| Convergence timeout | 150 s | deployer · `DEPLOYER_CONVERGENCE_TIMEOUT_SECONDS` |
| Tier-removal wait | 300 s | `off.sh --purge-intent-tier --remove-services` · `TIER_PURGE_WAIT_SECONDS` |
| Audit-record export | 120 s (a design value) | `off.sh` · `AUDIT_EXPORT_TIMEOUT_SECONDS` |

Override: the provider's `REVERIFY_INTERVAL` and `RECONCILE_INTERVAL` are optional keys
`reverify-interval` / `reconcile-interval` of ConfigMap `srl-provider-settings` in `agentic-netops-system`
(`kubectl -n agentic-netops-system patch configmap srl-provider-settings --type merge -p '{"data":{"reverify-interval":"2m"}}'`,
then `kubectl -n agentic-netops-system rollout restart deploy/srl-provider`); the tier's are `env` entries of
`deploy/agents/*.yaml`; the two script bounds are set in the environment of `off.sh`. The deletion of a service blocked
on an unreachable target has **no** bound at all.

### 9. Drift policy

- `DRIFT_POLICY` has **no default** and a **closed value set of one**: the exact string `revertive`. Unset, empty and every
  other value (`non-revertive`, `Revertive`, `true`) refuse the provider's start, naming the variable and the admissible value.
- Lab provisioning sets it (ConfigMap `srl-provider-settings`, key `drift-policy`). **A production deployment states it
  itself and never inherits it.** It lands on `spec.revertive: true` of every `Config` the provider generates — never absent.
- The device-configuration layer's non-revertive mode is **not admissible here**. It does not accept drift outright: it
  records the deviation and holds it for an operator to accept or revert. That is a shape the constitution would allow and
  this platform simply does not build — it has neither the `Ready=False` status shape a held deviation needs nor the path
  that clears one. Admitting another value would take its repair procedure, its status shape, its tests and its own entry
  in this runbook — not a constitution amendment (FR-015, AD-17, AD-34).

### 10. Audit record

- The audit record lives in the **analytics store** — ClickHouse, StatefulSet `clickhouse` in `agentic-netops-agents`,
  database `otel`, span tables `otel_traces*` — as span events named `audit.<event_type>` on the request trace.
  **Kubernetes Events are not the record**: the deployer mirrors three of its events there, and they expire.
- Query it from inside the pod (the credentials stay in the container's environment):

```bash
kubectl -n agentic-netops-agents exec clickhouse-0 -c clickhouse -- bash -c \
  'clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" --query "$0"' \
  "SELECT Timestamp, TraceId, arrayFilter(n -> startsWith(n, 'audit.'), Events.Name) AS audit
   FROM otel.otel_traces WHERE arrayExists(n -> startsWith(n, 'audit.'), Events.Name)
   ORDER BY Timestamp DESC LIMIT 20"
```

- Export it stand-alone (removes nothing): `CLUSTER_NAME=agentic-netops bash scripts/lib/audit_export.sh export`. It writes
  `audit-export-<attempt>.ndjson.gz`, its record `audit-export-<attempt>.json` and the usernames record
  `operator-usernames-<attempt>` under a new run directory of `.evidence/agentic-netops_agentic-netops-fabric/` (FR-078).
  `off.sh` and the tier's removal run the same export before anything removes the store.

### 11. Removing the intent tier

- `./scripts/off.sh --purge-intent-tier` removes the tier only; the cluster, the lab, the control plane and everything in
  `agentic-netops-services` stay, untouched either way.
- It does **not** remove the services the tier submitted: it lists the `Network`s in `agentic-netops-intent` and, while any
  exist, **refuses non-zero having changed nothing**, naming each. `--remove-services` is a word of its own because each of
  those services was created under two operator confirmations; with it they are deleted, then the namespace goes too.
- Order past the refusal: `supervisor`, `ui` and `deployer` are **scaled to zero first** (re-provisioning with
  `provision.sh --with-intent-tier` brings them back) → the authoritative list → the **audit record exported** (after the
  scale-down on every path) with the usernames record beside it → the listed `Network`s deleted and waited on for
  `TIER_PURGE_WAIT_SECONDS` (300 s) → only once a re-list is empty, the workloads, the tier's Secrets, provisional claims,
  the admission policy and both tier namespaces.
- Without `--remove-services`, a service that lands between the first list and the authoritative list sends the removal
  back to the refusal, with the workloads left scaled down and nothing deleted or exported (AD-46).
- The export lands at `.evidence/agentic-netops_agentic-netops-fabric/<UTC run id>/audit-export-<attempt>.ndjson.gz`, beside
  `operator-usernames-<attempt>`. Read it back with the audit reconciliation's file-source mode:
  `pytest agents/tests/e2e/test_audit_reconcile.py -v --audit-export "$(ls -t .evidence/agentic-netops_*/*/audit-export-*.ndjson.gz | head -1)"`.
- A re-run (data-model.md §16) **skips** the export when the lab's evidence root holds a verified one — exit status 0, rows
  written equal to the store's count, the same newest-row timestamp the store reports now, content hash intact — and records
  the skip; otherwise it **adds** a new attempt. It never rewrites one.
- `--discard-audit-record` goes past a **failed** export (the store is removed un-exported); its use is printed and recorded.
- A stop on an unreachable target names the `Network` and the target: wait for the target to return and re-run, or
  force-release by [the procedure above](#4-force-release-procedure) — never a shortcut. The script itself never force-releases.
- A full teardown (`off.sh` without `--purge-intent-tier`) destroys the environment and needs no such flag.

### 12. VNI and service VLAN cannot be edited

`spec.vlans[].vlan`, `spec.bridgeDomains[].vlan`, `spec.bridgeDomains[].l2vni` and `spec.routers[].l3vni` are immutable
once the `Network` is accepted (CEL rule `self == oldSelf`), and entries cannot be added, removed or renamed. The API
refuses the edit naming the field: changing it is **a removal and a new service** — delete the `Network` and create a new
one (AD-25). Adding or removing an attachment is still accepted.

### 13. Two VLAN bands

- An operator names VLANs **only from `100–999`** (the naming band); a named VLAN is never claimed.
- The allocation authority allocates **only from `1000–4000`** (the allocation band), when no VLAN was named.
- The bands are disjoint, so a named VLAN and an allocated one **cannot collide**.
- A refusal of a named VLAN in `1000–4000` means that band is the authority's to hand out: name one in `100–999`, or name
  none and let the tier allocate (FR-062, AD-33).

### 14. grafana-admin credential

Secret `grafana-admin` in `monitoring`, keys `admin-user` (default `admin`) and `admin-password`, **generated** at
provisioning and preserved on re-runs. There is no anonymous and no default login (FR-096). Read it into the environment:

```bash
GF_USER=$(kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-user}' | base64 -d)
GF_PASS=$(kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d)
kubectl -n monitoring port-forward svc/grafana 3000:3000 &
```

### 15. Who releases a claim

- **The tier** releases a claim only while it is **provisional** (decline, rollback, never submitted), and only for the
  correlation ids the deployer names — the allocator reads no `Network`.
- **The provider** owns every claim after submission: it adopts the tier's claims and releases them at finalization,
  **after the removal is read back** (held while a device is unreachable).
- An **adopted claim stays held** even after its value leaves the object (for example an attachment removed); it is released only at finalization.
- Read `status.claimRefs`: `name` (`<namespace>.<name>.<role>`), `namespace`, `indexKind`, `value`, `origin`
  (`adopted` or `created`) — FR-109, AD-32:
  `kubectl -n agentic-netops-intent get networks.fabric.agentic-netops.io <name> -o jsonpath='{.status.claimRefs}' | jq`.
  Never delete a claim by hand.

### 16. "One tagging mode per port" refusal

A port's tagging mode is declared in the `Fabric` inventory: tagged unless listed in that node's
`untaggedAccessPorts` (none are, in `examples/fabric/default-fabric.yaml`). An untagged and a tagged
attachment never share a port. The refusal comes before anything is created and **names the port and
both services**, e.g. `port leaf01 ethernet-1/1: Network <a> asks for a untagged attachment while Network <b> holds a tagged one`;
an attachment asking for the mode the inventory does not declare is refused listing the ports declared in that mode (FR-034).
Use a VLAN on both, or a port declared in the mode you need.

### 17. Network applied with kubectl — VNI claims and AllocationConflict

- The provider claims each stated `l2vni` / `l3vni` itself, **before any `Config`**, under the deterministic name
  `<namespace>.<name>.l2vni-<bridgeDomain>` / `<namespace>.<name>.l3vni-<router>`, marked `origin: created`.
- `Accepted=False/AllocationConflict` means the value is **held by another owner or outside the band** (VNI allocation band
  10000–20000 by default); the message names the value and the holder or the band, and **zero `Config`s** exist. The provider
  never picks another value for you.
- A VLAN in `1000–4000` on a `kubectl`-applied `Network` needs an adoptable claim; without one it is `AllocationConflict`
  naming the VLAN and both bands (`examples/constructs/negative/vlan-unclaimed-band.yaml` is that case) — FR-109.
- Check: `make test-provider-claims`, and `status.claimRefs` as above.

### 18. Structured logs and following a correlation id

- Every first-party workload writes **one JSON object per line** to stdout: `ts` (UTC, RFC 3339), `level`, `component`,
  `msg`, `kind` / `namespace` / `name`, `correlation_id`, and `thread_id` in the tier (NFR-014).
- The correlation id is the label `agentic-netops.io/correlation-id` on the `Network` and its claims, and **it is the trace id**.
- Follow one request across the provider and the agents:

```bash
CID=<correlation id>
kubectl -n agentic-netops-system logs deploy/srl-provider | jq -cR --arg id "$CID" 'fromjson? | select(.correlation_id==$id)'
for d in supervisor mapper allocator deployer; do
  kubectl -n agentic-netops-agents logs deploy/$d --all-containers | jq -cR --arg id "$CID" 'fromjson? | select(.correlation_id==$id)'
done
```

- In Grafana, the EVPN service-path dashboard links to `/d/intent-tier/intent-tier?var-correlation_id=<id>`. A log line is an
  aid; the outcome is always in a condition, an Event or a metric.

### 19. Host requirements

- Linux x86-64, CPU with **SSSE3**, kernel **≥ 4.10**, Docker able to run privileged containers; no hypervisor needed.
- Budget **≈2 vCPU and 2 GiB per SR Linux node** (four nodes), plus the Kind cluster (preflight default 4 vCPU / 6 GiB),
  plus the tier's summed requests (`bash scripts/lib/intent_tier.sh requests`). The preflight refuses a shortfall by name (NFR-004, NFR-012).
- **Measured per-node footprint** (T052, idle after convergence, no `Network`; `tests/integration/footprint.sh`;
  `.evidence/agentic-netops_agentic-netops-fabric/20260921T115335Z/footprint.summary.stdout`): RSS mean leaf01 ≈1342 MiB,
  leaf02 ≈1343 MiB, spine01 ≈1339 MiB, spine02 ≈1341 MiB; CPU mean ≈6.3–6.5 % of one CPU per node.
- **Dataplane packet-rate ceiling**: 1000 PPS documented for the unlicensed SR Linux container, ~5 kpps measured in research
  (documented / measured in research, not re-observed here). Tests assert reachability and isolation, never throughput (NFR-011).
- Every route past the probes needs an **authenticated operator** (FR-102), and a **deletion blocks on an unreachable
  target** with no timeout until it returns or is force-released (FR-103) — plan maintenance windows accordingly.
