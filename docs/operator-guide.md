# Operator guide — asking for services and reading what the tier reports

## Runbook standard

| | |
|---|---|
| **Audience** | The operator who asks the intent tier for network services — through the chat surface or the programmatic stream — and reads what it reports back. |
| **Scope** | Logging in; asking for a `vlan`, `mac-vrf`, `ip-vrf` or `acl` with both confirmations; asking for status and removal; reading progress, workflow statuses and `Ready` = `True` / `False` / `Unknown`; the refusals and what each means. Then the key facts of every topic the four documents share. |
| **What it assumes** | A lab provisioned with `./scripts/provision.sh --with-intent-tier` whose agents are healthy (see [`../TUTORIAL.md`](../TUTORIAL.md)), `kubectl` pointed at `kind-agentic-netops`, `curl` and `jq`. Nothing here reports an observed result: every **Expected** line is what the specification requires; a result is only a result once its evidence is captured. |
| **The four documents** | [`TUTORIAL.md`](../TUTORIAL.md) — the first bring-up walk-through. `docs/operator-guide.md` (this file) — asking for services through the tier and reading what it reports. [`docs/operations-guide.md`](operations-guide.md) — running the platform day to day: secrets, bounds, drift, audit, observability, host. [`docs/runbook.md`](runbook.md) — incident procedures, in full. |

Every procedure has the same shape: **When** · **Before you start** · **Steps** · **Expected** ·
**If it fails** · **Evidence**. Ask only in construct vocabulary — `vlan`, `mac-vrf`, `ip-vrf`,
`acl` — and only for ports the site has: `leaf01 ethernet-1/1` and `leaf02 ethernet-1/1`.

---

## Part 1 — Using the operator surface

### The two surfaces and the login

- **Chat surface**: `http://127.0.0.1:13000` (NodePort 30300, loopback only). It asks for the login before it renders anything.
- **Programmatic stream**: the supervisor at `http://127.0.0.1:19090` (NodePort 30990, loopback only). Five routes:
  `POST /agent/prompt/stream`, `GET /suggested-prompts`, `GET /transport/config` (all need the login) and
  `GET /health`, `GET /v1/health` (probes, no login).
- The login is HTTP Basic against the generated Secret `operator-credentials` (see [Operator credentials](#5-operator-credentials)).
  The principal recorded on every decision is **the username that authenticated** — the request body has no
  `principal` field, and a body that carries one is refused `400` naming the field.

```bash
OP_USER=$(kubectl -n agentic-netops-agents get secret operator-credentials -o jsonpath='{.data.username}' | base64 -d)
OP_PASS=$(kubectl -n agentic-netops-agents get secret operator-credentials -o jsonpath='{.data.password}' | base64 -d)
AUTH=(-u "$OP_USER:$OP_PASS")
curl -s "${AUTH[@]}" http://127.0.0.1:19090/suggested-prompts | jq
```

### Asking for a service with both confirmations

**When** — you want a new service.

**Before you start** — `curl -s http://127.0.0.1:19090/v1/health` answers `200` with every worker `ok`; `AUTH` is set.

**Steps** — one thread per request. The first message has no `thread_id`; every later one carries it.

```bash
S=http://127.0.0.1:19090/agent/prompt/stream
curl -sN "${AUTH[@]}" $S -H 'content-type: application/json' \
  -d '{"prompt":"Provision a vlan 120 on leaf01 ethernet-1/1 for tenant acme"}'
# chunk: MAPPED + the interpretation, then {"type":"confirmation_request","stage":"mapper",...}
curl -sN "${AUTH[@]}" $S -H 'content-type: application/json' \
  -d '{"prompt":"confirm","thread_id":"<thread_id>"}'
# chunk: ALLOCATED + the normalized intent (values exactly as rendered), then the second confirmation_request
curl -sN "${AUTH[@]}" $S -H 'content-type: application/json' \
  -d '{"prompt":"confirm","thread_id":"<thread_id>"}'
# chunks: PROVISIONING -> progress (VERIFIED, "ready":"True") -> final COMPLETED
```

Other prompts of the same shape: `"Extend vlan 100 as a mac-vrf across leaf01 ethernet-1/1 and leaf02 ethernet-1/1 for tenant blue"`,
`"Give tenant initech an ip-vrf carrying 10.50.0.0/24 on leaf01 ethernet-1/1 vlan 200"`,
`"Create a mac-vrf on vlan 110 across leaf01 ethernet-1/1 and leaf02 ethernet-1/1 for tenant umbrella with an anycast gateway at 10.60.0.1/24"`,
`"Apply an acl on leaf01 ethernet-1/1 vlan 120 for tenant acme: permit tcp 443 from 10.0.0.0/24, deny everything else"`.

**Expected**
- **First confirmation** (after `MAPPED`): what the tier understood, in construct terms. For an `acl` it states that rules are
  evaluated in ascending priority number and the first match wins, the usable range, and — when no default action was
  declared — that unmatched traffic is **accepted**.
- **Second confirmation** (after `ALLOCATED`): the claimed identifiers (VNI, and a VLAN from `1000–4000` only when you named
  none) and the derived values exactly as they will be rendered — EVI, instance names, subinterface indices, route targets.
- **No submission happens without the second confirmation.** Declining at either one submits nothing and releases every
  provisional claim; the thread stays resumable so you can amend the request.
- After the second confirmation: `PROVISIONING`, then `progress` chunks, then `final` `COMPLETED` only once the `Network`
  reports `Ready=True` after the two-sided read-back.

**If it fails** — an `error` chunk always names the stage and the reason, for example
`{"type":"error","stage":"allocator","status":"FAILED","reason":"…"}`. A bounded exit (3 iterations per turn or the 300 s
deadline) ends with a failed final chunk — never a hang. An unavailable worker or cluster API is named as a dependency
failure and the thread stays resumable.

**Evidence** — every confirmation, decline, submission and refusal is an audit event in the analytics store under the
correlation id; the created `Network` carries the label `agentic-netops.io/correlation-id`:
`kubectl -n agentic-netops-intent get networks.fabric.agentic-netops.io -l agentic-netops.io/correlation-id=<CID>`.

### Asking for status and removal

**When** — to see how a service stands, or to remove one.

**Before you start** — the service's name (`kubectl -n agentic-netops-intent get networks.fabric.agentic-netops.io`) or its thread.

**Steps** — ask in words on a thread: `"What is the status of <network name>?"` or `"Remove <network name>"`.

**Expected**
- A **status request takes no confirmation** and changes nothing; the answer is built from the **live object**.
- A **removal takes both confirmations**, like a creation. The deployer deletes the `Network` and watches it: `progress`
  chunks carry `"ready":"False","reason":"Deleting"`. Gone within the convergence timeout (150 s) → `final` `COMPLETED`.
  Still present → `final` with status `PROVISIONING` and a message such as
  `removal in progress: waiting on leaf02 (TargetUnreachable); it completes when the target returns` — in progress, not success, not an error.
- If someone changed the service with cluster tooling, the answer says first *modified outside the intent tier* or
  *deleted outside the intent tier* (the chunk carries `"out_of_band":"modified"` or `"deleted"`), then the live state.
  The tier writes nothing in response, and a removal asked of a modified service is not executed by that turn.

**If it fails** — the tier never offers a force-release; that is an operator action with cluster tooling
([Force-release procedure](#4-force-release-procedure)).

**Evidence** — the `remove` audit event is emitted when the delete is issued, whichever way the turn ends.

### Reading progress, statuses and Ready

- **Workflow status** is a closed set: `RECEIVED_REQUEST`, `VALIDATED`, `MAPPED`, `ALLOCATED`, `APPROVED`, `PROVISIONING`,
  `CONFIGURED`, `VERIFIED`, `COMPLETED`, `FAILED`, `STATUS_UNKNOWN`. Nothing else appears.
- **`STATUS_UNKNOWN` is never success**: the transport or the state store was lost mid-request. Ask for the status —
  it is re-read from the live object.
- **`ready` on a progress chunk is the `Ready` condition's status string**, three-valued:

| `ready` | Meaning | What to do |
|---|---|---|
| `"True"` | Converged: applied at the current generation **and** the two-sided read-back (written side and the device's own state) passed. | Nothing. |
| `"False"` | Not converged; the `reason` beside it names what. `Deleting` = a removal in progress, not a failure. `RoutesMissing`, `NotConverged` = the named invariant is missing. | Read the reason; for `Deleting`, the `Deleting` condition names what is outstanding. |
| `"Unknown"` | A re-verification **could not run** (`VerificationFailed`): the named target is unreachable or its read timed out. Not success and not failure. | Restore reachability to the named target; the next pass that runs returns `True` or `False`. |

Read the object directly:

```bash
kubectl -n agentic-netops-intent get networks.fabric.agentic-netops.io <name> \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status}/{.reason}: {.message}{"\n"}{end}'
```

### Refusals and what they mean

A refusal is a safety outcome: **nothing was created and nothing was claimed**.

| You see | Meaning | Do this |
|---|---|---|
| `401` / the login form will not go away | No credential, a wrong one, or it was rotated since you read it. No thread, no audit event. | Re-read `operator-credentials`. |
| `400` naming `principal` | The client asserts an identity in the body. | Remove the field; the login is the identity. |
| Refused naming an unsupported construct or property, offering the nearest construct | You asked for something outside the four constructs or not shown as qualified by the fabric's qualification record. | Rephrase with the construct offered. |
| Refused naming a VLAN and **two bands** | You named a VLAN outside `100–999` (the mapper refuses it before any claim). | See [Two VLAN bands](#13-two-vlan-bands). |
| Refused naming a node or port | Not in the site inventory; the refusal lists the valid ones. | Use `leaf01` / `leaf02` `ethernet-1/1`. |
| Refused naming a port and two services, for its tagging mode | See ["One tagging mode per port" refusal](#16-one-tagging-mode-per-port-refusal). | Use a VLAN on both, or another port. |
| Refused at the deployer pre-flight naming a service | An `acl` would bind a subinterface already filtered in that direction and address family. | Use another subinterface or family, or amend the holder. |
| Refused naming the declarative equivalent | You asked the tier to act on a device (a shell, a device session, "fix it yourself"). The tier cannot touch a device. | Ask for the construct. |
| `error` at the allocator naming a conflicting value | Allocation collision or exhaustion in the allocation band. | See [Who releases a claim](#15-who-releases-a-claim). |

---

## Part 2 — Reference: the nineteen topics

Full incident procedures are in [`docs/runbook.md`](runbook.md); the key facts are stated here.

### 1. Bring-up

The tier exists only after `MGMT_CIDR=172.25.25.0/24 ./scripts/provision.sh --cluster-name agentic-netops --with-intent-tier`
has passed every phase, in order: `NetworkReady` → `ClusterReady` → `LabReady` → `AppsReady` → `TargetsReady` → `GateReady` →
`FabricReady` → `ObservabilityReady` → `IntentTierReady`. `IntentTierReady` runs only with `--with-intent-tier`: the extended
preflight, the safety boundary with its denial probes before any agent exists, the analytics store (the audit record's home)
waited Ready, then the agents and the chat surface; it prints the two loopback URLs. Re-running is idempotent. Walk-through:
[`../TUTORIAL.md`](../TUTORIAL.md).

### 2. Teardown

`./scripts/off.sh --cluster-name agentic-netops` destroys the whole environment (lab, Secrets, allocation namespace, Kind
cluster, management network), exporting the audit record first whenever the store exists; a failed export stops it with the
store intact unless `--discard-audit-record` is given (printed and recorded). **Nothing under `.evidence/<cluster>_<lab>/` is
ever deleted**; `--preserve-evidence` only adds a capture. A second run is a no-op.

### 3. Per-stage failure diagnosis

The operator sees failures per **stage** of the request; provisioning failures per **phase** (`provisioning stopped at <Phase>`).

| Stage / phase | Look at |
|---|---|
| supervisor | `401`/`400`; bounded exit (iterations, deadline); `/v1/health` naming an unreachable worker; every worker unreachable with pods Running → the transport gateway (`slim`) and its port `46357`. |
| mapper | A schema reason (the model returned an out-of-contract reading — retry or rephrase); an unqualified construct or property (`kubectl -n agentic-netops-system get configmap fabric-qualification -o yaml`). |
| allocator | A conflicting value: `kubectl -n agentic-netops-allocation get identifierclaims.fabric.agentic-netops.io` (the first-party authority the lock file selects; under KUID `kubectl -n kuid-system get vlanclaims.vlan.be.kuid.dev,genidclaims.genid.be.kuid.dev`). |
| deployer | Dry-run rejection (names the object, nothing applied); pre-flight binding conflict; cluster API or admission webhook unavailable → `kubectl -n agentic-netops-system get pods` (the provider serves the webhook, which fails closed). |
| submitted, never Ready | A control-plane problem: the `Network`'s condition names the missing invariant; follow [`docs/runbook.md`](runbook.md). |
| provisioning phases | `NetworkReady` preflight/CIDR; `ClusterReady` Kind; `LabReady` containerlab; `AppsReady` **G11** (allocation authority); `TargetsReady` Targets (TLS, credentials, session limit); `GateReady` gate record; `FabricReady` `fabric01` conditions; `ObservabilityReady` absent series; `IntentTierReady` tier preflight, denial probes, pods. |

The full symptom table is the specification's quickstart §"Diagnosing a failure", carried in [`docs/runbook.md`](runbook.md).

### 4. Force-release procedure

**When** — only for a `Network` whose deletion is blocked `Deleting=True/TargetUnreachable` on a device that **will not return**.
If it will return, restore it; the deletion completes by itself (no deadline applies).

**Before you start** — this is never the tier's: both tier identities are denied the annotation at admission by the policy
`deny-tier-force-release`. Use cluster tooling as a cluster operator.

**Steps**

```bash
kubectl -n agentic-netops-intent annotate networks.fabric.agentic-netops.io <name> \
  fabric.agentic-netops.io/force-release="leaf02 decommissioned, ticket <id>"
kubectl -n agentic-netops-system get fabrics.fabric.agentic-netops.io fabric01 -o jsonpath='{.status.findings}' | jq
```

**Expected** — a `Warning` Event `ForceReleased`; the object gone and its claims released; a finding in
`Fabric.status.findings[]` naming the service, the device, the identifiers released and the rendered object names, stating the
device may still carry stale configuration (it may be orphaned there). While the device is away the `Fabric` is
`Ready=Unknown`/`Degraded=True/VerificationFailed`; once it returns with the finding open, `Degraded=True/StaleConfigurationPossible`.
The finding clears only after a clean scheduled read-back shows every named object absent.

**If it fails** — an empty reason is refused (`ForceReleaseRefused`); on an object not deleting or not blocked on
`TargetUnreachable` the annotation is ignored with an Event. Never remove the finalizer by hand.

**Evidence** — the finding (it outlives the `Network`) and the Events. Full procedure: [`docs/runbook.md`](runbook.md).

### 5. Operator credentials

Secret `operator-credentials` in `agentic-netops-agents`: `username` (default `operator`; `OPERATOR_USERNAME` at provisioning)
and a **generated** `password` (never from a flag, file or environment). Read both with
`kubectl -n agentic-netops-agents get secret operator-credentials -o jsonpath='{.data.username}' | base64 -d` (and `.data.password`).
Rotate: empty the password with `kubectl -n agentic-netops-agents patch secret operator-credentials --type merge -p '{"data":{"password":""}}'`,
then regenerate with `CLUSTER_NAME=agentic-netops bash scripts/lib/intent_secrets.sh operator-credentials` (or re-run
`provision.sh --with-intent-tier`); an existing password is otherwise preserved. The supervisor re-reads the mounted Secret
**without a restart**, and decisions recorded under the old credential stay valid. **Lab credentials over loopback HTTP —
not production-safe.**

### 6. Model-provider Secret

Secret `llm-provider` in `agentic-netops-agents`, from `AGENTIC_NETOPS_LLM_MODEL`, `AGENTIC_NETOPS_LLM_API_KEY`,
`AGENTIC_NETOPS_LLM_BASE_URL`, `AGENTIC_NETOPS_LLM_GATEWAY`. Declaring a gateway **requires a base URL** — otherwise refused
before the tier is created. The base URL is **preserved on re-provisioning** because the Secret is merged key by key. Change it
with a merge patch (`kubectl -n agentic-netops-agents patch secret llm-provider --type merge -p '{"stringData":{"LLM_MODEL":"…","API_KEY":"…"}}'`,
then `kubectl -n agentic-netops-agents rollout restart deploy/supervisor deploy/mapper deploy/allocator deploy/deployer`); clear
the base URL only with `AGENTIC_NETOPS_LLM_BASE_URL_CLEAR=1` on a provisioning run. **Never a whole-object replace**
(`kubectl replace`/`apply` of a full Secret drops the base URL). The endpoint is printed redacted (FR-106).

### 7. lastVerifiedTime and the stalled re-verification alert

`status.lastVerifiedTime` advances on every scheduled re-verification that **ran**, whatever it found. A pass that cannot run
leaves it where it was and sets `Ready=Unknown/VerificationFailed` naming the target — the `"Unknown"` you see in a progress
chunk or a status answer. The alert `ReverificationStalled` fires when
`time() - reverify_last_success_timestamp_seconds` exceeds one re-verification interval plus one reconciliation interval
(5 min + 15 s by default), whatever `Ready` says — it is the only signal for a `Ready=True` nobody re-read (FR-107).

### 8. Default bounds

What you feel as an operator (data-model.md §25; each an environment variable on its owner):

| Bound | Default | Variable |
|---|---|---|
| Iterations per request turn | 3 (a turn awaiting a confirmation does not count) | `SUPERVISOR_MAX_ITERATIONS` |
| Request deadline | 300 s, confirmation time excluded | `SUPERVISOR_REQUEST_DEADLINE_SECONDS` |
| Worker call timeout / retries | 60 s / 2 retries (1 s, 2 s), only "unreachable" retried | `WORKER_CALL_TIMEOUT_SECONDS` / `WORKER_CALL_RETRIES` |
| Deployer call timeout | 210 s | `DEPLOYER_CALL_TIMEOUT_SECONDS` |
| Convergence timeout (creation and removal watch) | 150 s | `DEPLOYER_CONVERGENCE_TIMEOUT_SECONDS` |
| Reconciliation interval | 15 s | `RECONCILE_INTERVAL` (provider) |
| Transient backoff | 250 ms, full jitter, cap 10 s, 6 attempts | `RETRY_BACKOFF_BASE`, `RETRY_BACKOFF_CAP`, `RETRY_MAX_ATTEMPTS` (provider) |
| Re-verification interval | 5 min, floor 30 s | `REVERIFY_INTERVAL` (provider) |
| Tier-removal wait | 300 s | `TIER_PURGE_WAIT_SECONDS` (`off.sh`) |
| Audit-record export | 120 s | `AUDIT_EXPORT_TIMEOUT_SECONDS` (`off.sh`) |

Override the tier's in the `env` of `deploy/agents/*.yaml`; the provider's `reverify-interval` / `reconcile-interval` in
ConfigMap `srl-provider-settings` (`agentic-netops-system`) then `kubectl -n agentic-netops-system rollout restart deploy/srl-provider`.
Start-up asserts convergence < deployer call < deadline. A deletion blocked on an unreachable target has no bound.

### 9. Drift policy

`DRIFT_POLICY` has **no default** and a **closed value set of one**, `revertive`; the provider refuses to start on anything
else, naming the variable. Lab provisioning sets it; **a production deployment states it itself and never inherits it**. It
lands on `spec.revertive: true` of every `Config`. The device-configuration layer's non-revertive mode is not admissible here:
it does not accept drift outright — it records the deviation and holds it for an operator to accept or revert — so it is a
shape the constitution would allow and this platform does not build, having neither the `Ready=False` status shape a held
deviation needs nor the path that clears one. Admitting another value would take its repair procedure, its status shape, its
tests and its own runbook entry — not a constitution amendment (FR-015, AD-17, AD-34). For the operator: the tier never
reverts an out-of-band edit to a `Network` (it reports it); the provider restores drift **on the device** to what the `Network` says.

### 10. Audit record

Every confirmation, decline, submission, removal, refusal and out-of-band detection is an audit event — a span event
`audit.<event_type>` on the request trace, carrying your authenticated username as `principal` — stored in the analytics
store (ClickHouse `clickhouse-0` in `agentic-netops-agents`, database `otel`, tables `otel_traces*`), **not in Kubernetes
Events** (a mirror that expires). Query it inside the pod:

```bash
kubectl -n agentic-netops-agents exec clickhouse-0 -c clickhouse -- bash -c \
  'clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" --query "$0"' \
  "SELECT Timestamp, arrayFilter(n -> startsWith(n, 'audit.'), Events.Name) FROM otel.otel_traces WHERE TraceId = '<CID>'"
```

Export it without removing anything: `CLUSTER_NAME=agentic-netops bash scripts/lib/audit_export.sh export` →
`.evidence/agentic-netops_agentic-netops-fabric/<UTC run id>/audit-export-<attempt>.ndjson.gz` (FR-078).

### 11. Removing the intent tier

- `./scripts/off.sh --purge-intent-tier` does **not** remove the services the tier submitted: it lists them and **refuses while
  they exist**, having changed nothing. `--remove-services` is a word of its own — each of those services was created under
  your two confirmations — and deletes them, then the namespace.
- Past the refusal, `supervisor`, `ui` and `deployer` are **scaled down first** (the chat surface goes away; re-provisioning with
  `provision.sh --with-intent-tier` brings them back), then the audit record is exported — always after the scale-down —
  with the usernames record beside it, under `.evidence/agentic-netops_agentic-netops-fabric/<UTC run id>/`.
- Read the export back: `pytest agents/tests/e2e/test_audit_reconcile.py -v --audit-export <audit-export-<attempt>.ndjson.gz>`.
- A re-run skips the export when a verified one exists (exit 0, rows = the store's count, the same newest-row timestamp, hash
  intact) and adds a new attempt otherwise — never rewrites (data-model.md §16). `--discard-audit-record` goes past a failed
  export and its use is recorded.
- Without `--remove-services`, a service landing between the two lists sends the removal back to the refusal, workloads left
  scaled down (AD-46).
- A stop on an unreachable target (`TIER_PURGE_WAIT_SECONDS`, 300 s): wait and re-run, or force-release by the procedure above —
  never a shortcut. Services in `agentic-netops-services` are untouched either way. A full teardown needs no such flag.

### 12. VNI and service VLAN cannot be edited

Once accepted, a service's VNIs (`l2vni`, `l3vni`) and service VLANs are immutable (CEL `self == oldSelf`). Asking the tier to
"change the VLAN" or "change the VNI" of a service is a removal (both confirmations) and a new request (both confirmations) —
AD-25. Adding or removing an attachment is an edit the API accepts.

### 13. Two VLAN bands

You name VLANs **only from `100–999`**; the allocation authority allocates **only from `1000–4000`** when you name none. The
bands are disjoint, so a named and an allocated VLAN cannot collide. A refusal of a named VLAN in `1000–4000` means that band is
the authority's to hand out — name one in `100–999`, or name none and let the tier allocate (FR-062, AD-33). The VLAN a
standalone `acl` names is a reference to an existing subinterface and is held to neither band.

### 14. grafana-admin credential

Secret `grafana-admin` in `monitoring` — `admin-user` (default `admin`) and a generated `admin-password`, preserved on re-runs;
no anonymous or default login (FR-096). Read with
`kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d`, then
`kubectl -n monitoring port-forward svc/grafana 3000:3000` and open the intent-tier dashboard.

### 15. Who releases a claim

The tier releases a claim only while it is **provisional** — you declined, the request rolled back or was never submitted — and
only for the correlation ids the deployer names. After submission the **provider** owns it: it adopts the tier's claims and
releases them at finalization after the removal is read back (held while a device is unreachable). An **adopted claim stays
held** even after its value leaves the object. Read them:
`kubectl -n agentic-netops-intent get networks.fabric.agentic-netops.io <name> -o jsonpath='{.status.claimRefs}' | jq` — each with
`name`, `namespace`, `indexKind`, `value`, `origin` (`adopted` for the tier's, `created` for the provider's) — FR-109, AD-32.

### 16. "One tagging mode per port" refusal

Tagging is a property of the port, declared in the `Fabric` inventory — tagged unless listed in `untaggedAccessPorts`. An
untagged and a tagged attachment never share a port; the refusal names **the port and both services**, before anything is
created, e.g. `port leaf01 ethernet-1/1: Network <a> asks for a untagged attachment while Network <b> holds a tagged one` (FR-034).
On this site both access ports are tagged, so name a VLAN.

### 17. Network applied with kubectl — VNI claims and AllocationConflict

A `Network` someone applies with `kubectl` (normally in `agentic-netops-services`) gets its VNI claims from the **provider**,
before any `Config`, named `<namespace>.<name>.l2vni-<bridgeDomain>` / `<namespace>.<name>.l3vni-<router>`, `origin: created`.
`Accepted=False/AllocationConflict` means the value is held by another owner or outside the band (VNI band 10000–20000 by
default): the message names the value and the holder or band, and zero `Config`s exist. A VLAN in `1000–4000` needs an adoptable
claim. The tier's own services show `origin: adopted` — the tier's claim, never a second one (FR-109).

### 18. Structured logs and following a correlation id

Each workload logs one JSON object per line: `ts` (UTC), `level`, `component`, `msg`, `kind`/`namespace`/`name`,
`correlation_id`, `thread_id` (NFR-014). The correlation id on your stream chunks is the label
`agentic-netops.io/correlation-id` and the trace id. Follow it:

```bash
CID=<correlation_id>
kubectl -n agentic-netops-system logs deploy/srl-provider | jq -cR --arg id "$CID" 'fromjson? | select(.correlation_id==$id)'
for d in supervisor mapper allocator deployer; do
  kubectl -n agentic-netops-agents logs deploy/$d --all-containers | jq -cR --arg id "$CID" 'fromjson? | select(.correlation_id==$id)'
done
```

In Grafana: `/d/intent-tier/intent-tier?var-correlation_id=<CID>`, linked from the EVPN service-path dashboard.

### 19. Host requirements

The lab host needs SSSE3 and kernel ≥ 4.10, ≈2 vCPU / 2 GiB per SR Linux node (four) plus the Kind cluster plus the tier's
requests (`bash scripts/lib/intent_tier.sh requests`). Measured per-node footprint (T052, idle after convergence,
`tests/integration/footprint.sh`, `.evidence/agentic-netops_agentic-netops-fabric/20260921T115335Z/footprint.summary.stdout`):
RSS mean ≈1339–1343 MiB (leaves ≈1342 / 1343 MiB), CPU mean ≈6.3–6.5 % of one CPU per node. Dataplane packet-rate ceiling:
1000 PPS documented for the unlicensed container, ~5 kpps measured in research — documented, not re-observed; never expect
throughput from the lab (NFR-004, NFR-011). Every surface route past the probes needs an authenticated operator (FR-102), and a
removal blocks on an unreachable target until it returns or is force-released (FR-103).
