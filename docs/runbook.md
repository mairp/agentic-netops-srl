# Runbook — Agentic NetOps on Nokia SR Linux

## Runbook standard

| | |
|---|---|
| **Audience** | The on-call operator of a provisioned lab who did not build the fabric or the tier (NFR-011). |
| **Scope** | Incident and change procedures: bring-up, teardown, per-stage failure diagnosis, the force-release, credentials and Secrets, bounds, the drift policy, the audit record, the tier's removal, identifier and tagging refusals, logs, host limits. |
| **Assumes** | A Linux host that passed the preflight (§19); the repository checked out; `kubectl`, `jq`, `docker`, `kind`, `containerlab` and `uv` on `PATH`; the Kind context `kind-agentic-netops` selected (`kubectl config use-context kind-agentic-netops`) — every `kubectl` below relies on it; the default names: cluster `agentic-netops`, lab `agentic-netops-fabric`, management network `agentic-netops-mgmt` on `172.25.25.0/24`, `Fabric` `fabric01`. |
| **Does not assume** | That anything written here was observed on your lab. Every **Expected** line is what the specification requires; the record of what a run did is its evidence under `.evidence/<cluster>_<lab>/<UTC run id>/` (constitution Principle I). |

**The four-document map** — one standard, four depths:

| Document | What it is for |
|---|---|
| `TUTORIAL.md` | The first bring-up, walked through end to end. |
| `docs/operator-guide.md` | Asking for services through the intent tier and reading what it reports. |
| `docs/operations-guide.md` | Running the platform day to day: secrets, bounds, drift, audit, observability, the host. |
| `docs/runbook.md` (this file) | Incident procedures, each complete. The other three point here for the full procedure. |

`README.md` is not one of the four; it is written separately (T164).

**The shape of every procedure.** Each topic below is written as: **When** (the trigger) ·
**Before you start** (what must be true, what to read first) · **Steps** (fenced commands, run from
the repository root) · **Expected** · **If it fails** · **Evidence** (where the record lands).

**Vocabulary.** A service is one of four constructs, in this order: `vlan`, `mac-vrf`, `ip-vrf`,
`acl`. They are the only names this runbook uses for services.

**Namespaces you will meet.** `agentic-netops-system` (the provider, the `Fabric`, the
authoritative qualification record), `agentic-netops-services` (the `Network`s applied with
`kubectl`; the tier never touches it), `agentic-netops-agents` (the tier's workloads, the analytics
store, the tier Secrets), `agentic-netops-intent` (the `Network`s the tier submitted),
`agentic-netops-allocation` (the first-party allocation authority this tree runs — see
`docs/operations/allocation-authority.md`; under the upstream authority it is `kuid-system`),
`sdc-system` (the device-configuration layer), `monitoring` (the observability stack).

---

## 1. Bring-up

**When.** A clean host; a lab torn down by `off.sh`; or a re-run to converge a lab that is already
up (the script is idempotent — it never recreates the cluster, never churns releases and reissues no
unchanged device configuration). Also the way back after the tier's removal scaled workloads down
(§11) — re-provisioning brings them back.

**Before you start.**
- The host meets §19. The management CIDR is free (the preflight refuses up front, naming the
  colliding Docker network, if not).
- For the tier: a model-provider credential in the environment (§6). A declared gateway without a
  base URL is refused before any tier workload exists.
- Optional: `OPERATOR_USERNAME` (default `operator`) — the password is always generated (§5).

**Steps.**

```bash
export AGENTIC_NETOPS_LLM_MODEL="…"          # §6 — consumed into the llm-provider Secret
export AGENTIC_NETOPS_LLM_API_KEY="…"
export AGENTIC_NETOPS_LLM_BASE_URL="…"       # required when AGENTIC_NETOPS_LLM_GATEWAY is set
MGMT_CIDR=172.25.25.0/24 ./scripts/provision.sh --cluster-name agentic-netops --with-intent-tier
```

Without `--with-intent-tier` the script stops after `ObservabilityReady`: the control plane is
complete and usable without the tier. There is no flag or variable that skips, reorders or selects
phases, none that skips a gate, and none that selects a device profile or an allocator (the
allocation authority is `versions.lock.yaml` `allocationAuthority.kind`, nothing else — FR-104).

The phases, in order, each waited on with a bounded timeout (`PROVISION_WAIT_TIMEOUT` 300 s,
`PROVISION_TARGETS_TIMEOUT` 600 s, `PROVISION_FABRIC_TIMEOUT` 900 s, `OBS_WAIT_TIMEOUT` 300 s):

| Phase | True before the next phase starts |
|---|---|
| `NetworkReady` | pins verified (`make verify-pins`), host preflight passed; the owned Docker network `agentic-netops-mgmt` exists on `MGMT_CIDR` |
| `ClusterReady` | the pinned Kind cluster exists and every node is attached to the management network |
| `LabReady` | the containerlab topology `lab/topology.clab.yml` is deployed; every device's gNMI port `57400` accepts a connection (a credential-less accept, no RPC) |
| `AppsReady` | cert-manager → the allocation authority the lock file selects → gate item **G11** (on failure provisioning stops here, non-zero, naming G11) → its seed pools → the device-configuration layer → the provider, with `DRIFT_POLICY=revertive` written first (§9) |
| `TargetsReady` | lab Secrets (device credentials, `monitoring` namespace, `grafana-admin`), the schema mirror, onboarding; the four device `Target`s Ready; the device metric collector |
| `GateReady` | the capability gate ran to completion and the qualification record is published (`agentic-netops-system/fabric-qualification`) |
| `FabricReady` | `examples/fabric/` applied; `Fabric` `fabric01` reports `Ready=True` (underlay, EVPN overlay with its family negotiated, reflector settings read back) |
| `ObservabilityReady` | the streaming-telemetry subscriber, the collector, Prometheus and Grafana installed into `monitoring` from the same inventory; the live series names re-checked against the gate's observation; only then the alert rules loaded |
| `IntentTierReady` | (`--with-intent-tier`) extended preflight with the tier's summed requests; the safety boundary (namespaces, ServiceAccounts, Roles, NetworkPolicies, `deny-tier-force-release`, the generated Secrets including `operator-credentials`) and the **denial probes before any agent workload exists**; then the analytics store `clickhouse` and `agent-otel-collector` waited Ready; then `slim`, `supervisor`, `mapper`, `allocator`, `deployer`, `ui`; the operator username (never the password) captured into evidence |

**Expected.** The script exits `0` with no undocumented manual step. The supervisor is published on
`127.0.0.1:19090` and the chat surface on `127.0.0.1:13000` (loopback only). A second run reports
convergence and changes nothing.

```bash
kubectl -n agentic-netops-system get fabrics.fabric.agentic-netops.io fabric01    # Ready=True
kubectl -n agentic-netops-agents get deploy,sts,po                               # all Ready
curl -s 127.0.0.1:19090/health                                                   # {"status":"ok"}
curl -s 127.0.0.1:19090/v1/health | jq                                           # mapper, allocator, deployer "ok"
```

**If it fails.** The script exits non-zero naming the phase and the cause. Go to §3 for that phase.
Re-running after the fix is always safe; it resumes by converging what exists.

**Evidence.** Every captured step is written through `evidence_run` under
`.evidence/agentic-netops_agentic-netops-fabric/<UTC run id>/` (command, UTC timestamp, exit status,
device image digest, cluster and lab identity — NFR-013). The gate's raw observations are also in
`tests/gate/observed/`. Check a run with `make verify-evidence` (default: the newest run).

---

## 2. Teardown

**When.** The lab is finished with, must be rebuilt from clean, or is half-provisioned and you want
it gone. `off.sh` tolerates partial provisioning.

**Before you start.**
- Decide whether you want a capture of the state about to be removed (`--preserve-evidence` *adds*
  that capture; it is never what keeps evidence).
- If the tier is up, run the audit reconciliation (§10) first while the store and the live objects
  both exist — afterwards only the exported file remains.

**Steps.**

```bash
./scripts/off.sh --cluster-name agentic-netops                       # full teardown
./scripts/off.sh --cluster-name agentic-netops --preserve-evidence   # plus a teardown-time capture
```

Order inside the script: ownership plan (read-only; any present-but-unowned target refuses the whole
run with nothing deleted) → optional capture → **audit-record export whenever the analytics store
exists, requested or not** → the containerlab lab → the generated Secrets (the lab's, then the
tier's; the operator `username` captured first, never the `password`) → the first-party authority's
namespace → the Kind cluster → the owned management network.

A full teardown needs no `--remove-services`: it destroys the cluster and every `Network` with it.
To remove the tier only, see §11.

**Expected.** Exit `0`. Running it again is a successful no-op. Nothing unrelated is touched: only
resources labelled `agentic-netops.io/owned-by=agentic-netops` are deleted. Pinned and built images
are retained.

**The evidence root is never deleted.** Nothing under `.evidence/<cluster>_<lab>/` is removed by
`off.sh`, by the full teardown or by the tier's removal, with `--preserve-evidence` or without it
(FR-010, AD-64).

**If it fails.** Exit `1` names the refused or failed step; exit `2` is a usage error.
- *Refused: present but not owned* — something with the platform's name exists without the ownership
  label. It is not the platform's; remove or rename it yourself, or use another `--cluster-name`.
- *Audit export failed* — the teardown stops with the store intact. Fix the store (§10, **If it
  fails**) and re-run. Only if the record is knowingly to be abandoned:
  `./scripts/off.sh --cluster-name agentic-netops --discard-audit-record` — its use is printed and
  recorded in the run's evidence.

**Evidence.** The run's `EVIDENCE_DIR`: the ownership plan, the export
(`audit-export-<attempt>.ndjson.gz` and its record), the usernames record, and with
`--preserve-evidence` the pre-teardown capture.

---

## 3. Per-stage failure diagnosis

**When.** `provision.sh` exited non-zero naming a phase; or a lab that was Ready reports something
that is not. The platform degrades legibly: each dependency failure names itself.

**Before you start.** Read the last `ERROR` lines the script printed (lifecycle scripts log with a
level and phase prefix; they are not JSON). Note the `EVIDENCE_DIR` it named.

**Steps — by phase.**

`NetworkReady` — pins and host.

```bash
make verify-pins                        # a pin that does not resolve is named
grep -m1 -ow ssse3 /proc/cpuinfo; uname -r
docker network ls; ip route             # compare with MGMT_CIDR
```
Refusals name the cause: a CIDR colliding with a Docker network, a host route, the pod or service
CIDR (re-run with `MGMT_CIDR=<free /24>`); no SSSE3; kernel older than 4.10; vCPU or memory short
(the message states the shortfall and the breakdown).

`ClusterReady` — the Kind cluster.

```bash
kind get clusters
docker network inspect agentic-netops-mgmt | jq '.[0].Containers'   # every Kind node attached
```

`LabReady` — the containerlab topology.

```bash
containerlab inspect -t lab/topology.clab.yml
docker ps --filter label=clab-node-kind=nokia_srlinux
```
A device whose port `57400` never accepts is usually still booting or short of memory (§19).

`AppsReady` — cert-manager, the authority, G11, the device-configuration layer, the provider.

```bash
kubectl -n cert-manager get pods
kubectl -n agentic-netops-allocation get deploy,pods,identifierpools,identifierclaims   # first-party
kubectl get apiservice | grep be.kuid.dev; kubectl -n kuid-system get pods             # upstream kuid
kubectl -n sdc-system get pods
kubectl -n agentic-netops-system get pods
kubectl -n agentic-netops-system logs deploy/srl-provider | tail -20
```
*Stopped naming G11*: the authority failed its claim round-trip. Nothing is substituted for you. Read
`$EVIDENCE_DIR/g11-observations.json` (it names `authority.kind`); fix the authority, or record the
operator decision in `docs/decisions/allocator-substitution.md` and follow
`docs/operations/allocation-authority.md`. *Provider will not start, naming `DRIFT_POLICY` or
`REVERIFY_INTERVAL`*: §9, §8.

`TargetsReady` — the device targets.

```bash
kubectl -n agentic-netops-system get targets.config.sdcio.dev
make wait-targets
```
A target that never reaches Ready: TLS, credentials (`srl-credentials` in `agentic-netops-system`)
or the device's shared gRPC session limit — the device-configuration layer and the metric collector
draw from the same pool.

`GateReady` — the capability gate.

```bash
kubectl -n agentic-netops-system get configmap fabric-qualification -o yaml
ls tests/gate/observed/
```
A failed item is never skipped, never weakened and never routed to a second profile — there is none.
It is fixed or recorded, and the construct or property it gates is refused by name (FR-097). A re-run
on a lab already carrying the platform fabric reuses the record only when it is this gate's pass for
this cluster, lab and image; otherwise re-qualify on stock nodes: `off.sh`, then `provision.sh`.

`FabricReady` — the default `Fabric`.

```bash
kubectl -n agentic-netops-system get fabrics.fabric.agentic-netops.io fabric01 -o jsonpath='{range .status.conditions[*]}{.type}={.status}/{.reason}: {.message}{"\n"}{end}'
make verify-fabric-control-plane
make show-bgp; make show-allocations
```
Every session up and zero EVPN routes: correct while no service spans two leaves; otherwise check the
spines' `inter-as-vpn` and route-reflector settings (the `Fabric` read-back checks both).

`ObservabilityReady` — the stack in `monitoring`.

```bash
kubectl -n monitoring get deploy,pods
make wait-observability
```
A recorded series name absent from the installed Prometheus, or a differing naming setting, stops
the phase naming it, and the alert rules are not loaded. A telemetry-only outage does not fail
network convergence; it does fail observability acceptance until recovered.

`IntentTierReady` — the tier.

```bash
scripts/lib/intent_tier.sh requests                          # the requests the tier adds to the preflight
kubectl -n agentic-netops-agents get deploy,sts,po
make test-boundary                                           # the denial probes, standalone
kubectl -n agentic-netops-agents logs deploy/supervisor | tail -20
```
A denial the probes did not observe aborts the phase before any agent workload exists — that is the
safety boundary working, not a flake. A refused `llm-provider` (gateway without base URL) happens
before anything of the tier is written (§6).

**Symptoms on a running lab.**

| Symptom | Look at | What to do |
|---|---|---|
| `kubectl apply` of a `Network` fails with a webhook-call error | `kubectl -n agentic-netops-system get pods` | The provider serves the admission webhook, which fails closed. Retry once it is Ready. A `kubectl delete` still works and blocks on the finalizer. |
| `Ready=Unknown/VerificationFailed` | the condition's message names the target | §7 — not a success and not a failure; restore management reachability to the named target. |
| `Deleting=True/TargetUnreachable` | the `Deleting` condition | Restore the device; the removal completes by itself. No timeout to wait out. §4 only for a device that is not coming back. |
| `Accepted=False/AllocationConflict` | the message (value and holder or band) | §17, §13. |
| Refused naming a port and two services | the message | §16. |
| `Fabric` `Degraded=True/StaleConfigurationPossible` | `.status.findings` | §4 — clears after a clean scheduled read-back of the named device. |
| `401` from the supervisor or a login form that will not go away | `operator-credentials` | §5. A `400` naming `principal`: the client asserts an identity in the body — remove the field. |
| Deep health names a worker unreachable | `kubectl -n agentic-netops-agents get po -l app=<worker>` | Restart or fix that worker; the supervisor is NotReady, not restarted, so threads survive. |
| Every worker unreachable, pods Running | `kubectl -n agentic-netops-agents logs deploy/slim` | The transport gateway or its TLS; endpoint port `46357`. |
| `STATUS_UNKNOWN` | the checkpointer PVC `supervisor-checkpoint`, the gateway | Never treat as success. |
| A service submitted, never Ready | the `Network`'s conditions | A control-plane problem, not a tier one; the condition names the missing invariant. |

**Expected.** Each failure is identified by the phase or condition that names it, without reading
process logs; logs (§18) are an aid.

**If it fails.** If no condition, Event or metric names the cause, that is itself a defect (NFR-005):
record it with the evidence directory and the correlation id.

**Evidence.** The failing run's `EVIDENCE_DIR`; the object's conditions and Events
(`kubectl describe`); `quickstart.md` §"Diagnosing a failure" is the full symptom table.

---

## 4. Force-release procedure

**When — and only when — it is justified.** A `Network` is being deleted and is blocked with
`Deleting=True`, reason `TargetUnreachable`, on a device that **will not return** (decommissioned,
replaced, lost). A device that is only temporarily away needs nothing: restore its management
reachability and the removal completes by itself, reading the removal back and releasing every
claim. Nothing on the deletion path has a deadline; waiting longer changes nothing (FR-103).

The force-release is **not** an exit from any other wait: not from an access-list holder
(`HolderPresent`), not from an allocation authority that has not answered, not from a live service.

**Before you start.**
- Confirm the block:

```bash
NS=agentic-netops-services           # or agentic-netops-intent for a tier-submitted service
N=<network name>
kubectl -n $NS get networks.fabric.agentic-netops.io $N \
  -o jsonpath='{.status.conditions[?(@.type=="Deleting")]}' | jq     # status True, reason TargetUnreachable, message names the node
kubectl -n $NS get networks.fabric.agentic-netops.io $N -o jsonpath='{.status.claimRefs}' | jq
```
- Have a reason you would put in a ticket: it becomes the finding's `reason`. An empty reason is
  refused.
- Accept the consequence: **the released identifiers may still be configured on the unreachable
  device** — configuration may be orphaned there, and the platform records that instead of hiding it.
- You must act as an operator with cluster tooling. The tier's identities (`intent-deployer`,
  `intent-allocator`) are **denied at admission** by the `deny-tier-force-release` policy — the
  identity that reads operator text can never release an identifier a device may still carry.

**Steps.**

```bash
kubectl -n $NS annotate networks.fabric.agentic-netops.io $N \
  fabric.agentic-netops.io/force-release="leaf02 decommissioned, ticket <id>"
kubectl -n $NS get events --field-selector involvedObject.name=$N | grep -E 'ForceRelease'
kubectl -n agentic-netops-system get fabrics.fabric.agentic-netops.io fabric01 -o jsonpath='{.status.findings}' | jq
```

**Expected.**
- The annotation is honoured **only** on a `Network` being deleted **and** blocked on
  `TargetUnreachable`. Anywhere else it is ignored with a `Warning` Event `ForceReleaseIgnored` and
  nothing is released; an empty value gives `ForceReleaseRefused`. It is never a way to delete.
- Honoured: first, per unreachable device, a finding appended to `Fabric.status.findings[]` (type
  `StaleConfigurationPossible`, the service's namespace, name and UID, the node, every identifier
  released, the device object names the service had rendered there, your reason, the time) and a
  `Warning` Event `ForceReleased`; then `Deleting=True/ForceReleased`, every `status.claimRefs` entry
  released, the finalizer removed, the object gone.
- The finding **outlives the service**. While the device is still away the `Fabric` is
  `Ready=Unknown` with `Degraded=True/VerificationFailed` naming it; once the device returns with the
  finding open, the `Fabric` reports `Degraded=True/StaleConfigurationPossible` beside `Ready=True`.
  While the finding is open, a render that would produce one of its objects on that node is refused
  `Applied=False/OwnershipConflict` naming the finding.
- **The finding clears only after a clean scheduled read-back**: the `Fabric`'s re-verification
  reads every named object absent from that device. There is no manual clear.

**If it fails.** `ForceReleaseIgnored` names why (not deleting, not `TargetUnreachable`, a holder, an
authority wait) — fix that instead. `ForceReleaseRefused` names a missing reason, no `Fabric` to
record on, or device objects that cannot be stated. A denial at admission means you are using a tier
identity. If the returned device still carries the orphaned objects, the finding stays open —
remove that configuration through the platform (re-apply and delete a service that owns those
paths) or re-provision the node; never delete a claim by hand.

**Evidence.** The `ForceReleased` Events; `Fabric.status.findings[]` (durable until cleared); the
live proof is `make test-delete-unreachable FORCE_RELEASE=1` (SC-043), which writes to its run's
evidence directory.

---

## 5. Operator credentials

**When.** You need to log in to the chat surface or call the supervisor; a `401`; a suspected leak;
a scheduled rotation.

**Before you start.** Know what they are: Secret `operator-credentials` in `agentic-netops-agents`,
keys `username` (default `operator`, set by `OPERATOR_USERNAME` at provisioning) and `password`
(always generated; never accepted from the environment, a flag or a file — `OPERATOR_PASSWORD` is
ignored with a warning). **These are lab credentials: HTTP Basic over the loopback-only port
mappings, not production-safe** (FR-019); one operator is the reference scale. Every route except
`/health` and `/v1/health` requires them (FR-102); the principal recorded on every audit event is
the authenticated username, never one a caller asserts.

**Steps — read them.**

```bash
OP_USER=$(kubectl -n agentic-netops-agents get secret operator-credentials -o jsonpath='{.data.username}' | base64 -d)
OP_PASS=$(kubectl -n agentic-netops-agents get secret operator-credentials -o jsonpath='{.data.password}' | base64 -d)
curl -s -u "$OP_USER:$OP_PASS" 127.0.0.1:19090/transport/config
```
Never paste either value into a manifest, a log, a ticket or an evidence file.

**Steps — rotate the password.** Provisioning preserves an existing password byte-identical, so a
rotation removes the stored one and lets the generator write a new one (a merge patch of that key
only):

```bash
kubectl -n agentic-netops-agents patch secret operator-credentials --type json \
  -p '[{"op":"remove","path":"/data/password"}]'
CLUSTER_NAME=agentic-netops scripts/lib/intent_secrets.sh operator-credentials
# or, equivalently, re-run provisioning: ./scripts/provision.sh --cluster-name agentic-netops --with-intent-tier
```
The supervisor reads the mounted Secret file on each check and needs **no restart**; allow the
kubelet's Secret sync period before the new value is in effect. Changing the **username** is
possible (`OPERATOR_USERNAME=<new>` on the same command) but makes the run's usernames set larger
than one, which invalidates the single-operator authentication measure (SC-042) for that run, and
the record says so.

**Expected.** Old password → `401` with a `WWW-Authenticate: Basic` challenge; new one → `200`.
Audit events recorded under the old credential stay valid.

**If it fails.** `401` with the new value: wait out the kubelet sync, then re-read the Secret. The
generator refuses a Secret without the ownership label (it is not the platform's) and refuses any
password argument.

**Evidence.** Every provisioning run captures the `username` (never the password) as
`operator-username-<attempt>` in its `EVIDENCE_DIR`; refusals move
`agentic_netops_agent_auth_refusals_total` and emit no audit event.

---

## 6. Model-provider Secret

**When.** Setting up the model provider, switching provider or model, declaring a shared gateway,
changing or clearing the base URL.

**Before you start.** Secret `llm-provider` in `agentic-netops-agents`, generated at provisioning
from four inputs:

| Input (environment of `provision.sh`) | Stored key |
|---|---|
| `AGENTIC_NETOPS_LLM_MODEL` (e.g. `openai/…`, `anthropic/…` — the prefix selects the provider) | `LLM_MODEL` |
| `AGENTIC_NETOPS_LLM_API_KEY` | `API_KEY` |
| `AGENTIC_NETOPS_LLM_BASE_URL` | `BASE_URL` |
| `AGENTIC_NETOPS_LLM_GATEWAY` (the gateway's name, when the endpoint is a shared gateway) | `GATEWAY` |

Rules (FR-106):
- **Declaring a gateway requires a base URL.** A declared gateway whose base URL (given, else
  stored) is empty is refused before anything is written; an agent whose Secret declares a gateway
  without a base URL refuses to start; one whose Secret loses its base URL while running stops
  calling the model and reports it — it never falls back to the library default.
- **The base URL is preserved on re-provisioning** because the Secret is *merged*: an input you do
  not set (or set empty) keeps its stored value.
- **Clearing** it takes exactly `AGENTIC_NETOPS_LLM_BASE_URL_CLEAR=1`; together with a new base URL
  it is refused as contradictory.
- **Never a whole-object replace.** `kubectl replace`, or `kubectl apply` / `create … | apply` of a
  full Secret, deletes every key it omits — that is how a base URL is silently lost.
- The endpoint is printed **redacted**: user-info and credential-bearing query parameters become
  `***`; host, port and path stay visible.

**Steps — change with a merge patch.**

```bash
kubectl -n agentic-netops-agents patch secret llm-provider --type merge \
  -p '{"stringData":{"LLM_MODEL":"<prefix>/<model>","API_KEY":"<key>"}}'
# a different endpoint is changed explicitly, in the same kind of patch
kubectl -n agentic-netops-agents patch secret llm-provider --type merge \
  -p '{"stringData":{"BASE_URL":"https://gateway.example/v1","GATEWAY":"<gateway name>"}}'
```
Or through provisioning, which merges the same way and prints the redacted endpoint:

```bash
AGENTIC_NETOPS_LLM_MODEL="<prefix>/<model>" ./scripts/provision.sh --cluster-name agentic-netops --with-intent-tier
AGENTIC_NETOPS_LLM_BASE_URL_CLEAR=1 ./scripts/provision.sh --cluster-name agentic-netops --with-intent-tier   # clear
```

**Expected.** The Secret is mounted read-only and read on every model call, so no restart is needed
once the kubelet has synced the file (a `kubectl -n agentic-netops-agents rollout restart deploy/supervisor deploy/mapper deploy/allocator deploy/deployer`
makes it immediate). Each agent's start-up log names the endpoint it will call, redacted. The
stored base URL is byte-identical before and after a provisioning run that did not set it:

```bash
scripts/lib/intent_secrets.sh redact-url "$(kubectl -n agentic-netops-agents get secret llm-provider -o jsonpath='{.data.BASE_URL}' | base64 -d)"
```

**If it fails.** "gateway declared but no base URL" — set `AGENTIC_NETOPS_LLM_BASE_URL`. Model calls
fail after a change — check the key and the model prefix; the mapper's failure names the dependency
(NFR-010). A base URL lost after someone replaced the Secret — patch it back explicitly.

**Evidence.** The provisioning run's log line `llm-provider: model calls will go to <redacted>`;
the agents' start-up log lines; traces carry the model identity per call (NFR-009).

---

## 7. lastVerifiedTime and the stalled re-verification alert

**When.** You want to know whether a `Ready=True` is current; the `ReverificationStalled` alert
fired; a `Fabric` or `Network` shows `Ready=Unknown`.

**Before you start.** What the fields mean (FR-107):
- `Ready=True` is never a memory. The provider re-verifies every `Fabric` and `Network` on a schedule
  (`REVERIFY_INTERVAL`, 5 min default, §8), reading the device state back.
- `status.lastVerifiedTime` **advances on every pass that ran, whatever it found** — including a pass
  that found an invariant missing and set `Ready=False` (e.g. `RoutesMissing`).
- A pass that **cannot run** (target unreachable, read timed out) sets `Ready=Unknown` and
  `Degraded=True`, both with reason `VerificationFailed` naming the target, and `lastVerifiedTime`
  stops advancing. This is **not a success and not a failure**: nothing is known to be lost and
  nothing is known to be there. It is never `Ready=False` (an outage is not a lost invariant) and
  never a `Ready=True` left standing.
- The `ReverificationStalled` alert (`deploy/observability/prometheus/rules/reconcile.yaml`) fires when
  `time() - reverify_last_success_timestamp_seconds` exceeds **one re-verification interval plus one
  reconciliation interval** for an object.

**Steps.**

```bash
kubectl -n agentic-netops-services get networks.fabric.agentic-netops.io <name> \
  -o jsonpath='{.status.lastVerifiedTime}{"\n"}{range .status.conditions[*]}{.type}={.status}/{.reason}: {.message}{"\n"}{end}'
kubectl -n agentic-netops-system get fabrics.fabric.agentic-netops.io fabric01 -o jsonpath='{.status.lastVerifiedTime}{"\n"}'
kubectl get --raw '/api/v1/namespaces/monitoring/services/prometheus:9090/proxy/api/v1/alerts' \
  | jq '.data.alerts[] | select(.labels.alertname=="ReverificationStalled")'
```

**Expected.** `lastVerifiedTime` within one interval of now on every object. On a stall: the object
reports `Ready=Unknown/VerificationFailed` naming the target. Restore that target's management
reachability; the first pass that runs returns `Ready=True` or sets `Ready=False` naming what is
missing, and the alert resolves.

**If it fails.** Alert firing but no object `Unknown`: the provider itself is not running passes —
check `kubectl -n agentic-netops-system get pods` and its logs. `lastVerifiedTime` advancing while
`Ready=False`: that is correct — the pass ran and found something missing; read the reason.

**Evidence.** `make test-reverify` (SC-044) exercises both halves and records them; the alert's
history is in Prometheus.

---

## 8. Default bounds

**When.** A timeout or retry behaves unexpectedly; you need a shorter re-verification interval for
a test; you are sizing a deployment.

**Before you start.** Every bound has one default (data-model.md §25), set by an environment
variable on the workload that owns it — never a rebuild. A test asserts each default and that each
override is honoured.

| Bound | Default | Owner · variable |
|---|---|---|
| Reconciliation interval | 15 s | provider · `RECONCILE_INTERVAL` |
| Transient-error backoff | exponential from 250 ms, full jitter, cap 10 s, at most 6 attempts | provider · `RETRY_BACKOFF_BASE`, `RETRY_BACKOFF_CAP`, `RETRY_MAX_ATTEMPTS` |
| Re-verification interval | 5 min, **floor 30 s** — shorter or unparseable refuses the provider's start naming the variable | provider · `REVERIFY_INTERVAL` |
| Orchestration iteration limit | 3 per request turn (a turn awaiting confirmation does not count) | supervisor · `SUPERVISOR_MAX_ITERATIONS` |
| Request wall-clock deadline | 300 s, confirmation time excluded | supervisor · `SUPERVISOR_REQUEST_DEADLINE_SECONDS` |
| Worker call timeout | 60 s | supervisor · `WORKER_CALL_TIMEOUT_SECONDS` |
| Deployer call timeout | 210 s | supervisor · `DEPLOYER_CALL_TIMEOUT_SECONDS` |
| Worker call retries | 2 (1 s, then 2 s); only "unreachable" is retried | supervisor · `WORKER_CALL_RETRIES` |
| Convergence timeout | 150 s | deployer · `DEPLOYER_CONVERGENCE_TIMEOUT_SECONDS` |
| Allocation-authority retry | the worker-call rule, then a named failure | allocator agent |
| Tier-removal wait | 300 s | `off.sh --purge-intent-tier --remove-services` · `TIER_PURGE_WAIT_SECONDS` |
| Audit-record export | 120 s (a design value, not a measurement) | `off.sh` · `AUDIT_EXPORT_TIMEOUT_SECONDS` |

Invariant, asserted at start-up: convergence timeout < deployer call timeout < request deadline
≤ five minutes. The delete-while-unreachable state has **no bound at all**. `DRIFT_POLICY` is not a
bound and has no default (§9).

**Steps — override.**

```bash
# provider: REVERIFY_INTERVAL and RECONCILE_INTERVAL are read from ConfigMap srl-provider-settings (optional keys)
kubectl -n agentic-netops-system patch configmap srl-provider-settings --type merge \
  -p '{"data":{"reverify-interval":"2m","reconcile-interval":"15s"}}'
# provider: the backoff variables, directly on the Deployment
kubectl -n agentic-netops-system set env deploy/srl-provider RETRY_BACKOFF_BASE=500ms RETRY_MAX_ATTEMPTS=6
kubectl -n agentic-netops-system rollout restart deploy/srl-provider

# tier: the supervisor's and deployer's variables are set in deploy/agents/supervisor.yaml and deploy/agents/deployer.yaml
kubectl -n agentic-netops-agents set env deploy/supervisor SUPERVISOR_REQUEST_DEADLINE_SECONDS=300

# lifecycle scripts: per invocation
TIER_PURGE_WAIT_SECONDS=600 AUDIT_EXPORT_TIMEOUT_SECONDS=240 ./scripts/off.sh --purge-intent-tier --remove-services
```
A `kubectl set env` on a tier Deployment is a live change; the durable one is the manifest under
`deploy/agents/` followed by `provision.sh --with-intent-tier`, which re-applies those manifests.

**Expected.** The workload restarts with the new value; the provider or the supervisor refuses to
start on a value that breaks a floor or the invariant, naming the variable.

**If it fails.** `CrashLoopBackOff` on the provider after an override — read its log; it names the
variable and the admissible range. Remove the override to return to the default.

**Evidence.** The workload's start-up log; `agentic_netops_reverify_interval_seconds` and
`agentic_netops_reconcile_interval_seconds` in Prometheus show the provider's effective intervals.

---

## 9. Drift policy

**When.** The provider will not start naming `DRIFT_POLICY`; you are writing a deployment outside
the lab; someone asks for a non-revertive mode.

**Before you start.** The rules (FR-015, AD-17, AD-34):
- `DRIFT_POLICY` has **no default**. Its value set is **closed and has one member**: the exact
  string `revertive`. Unset, empty and every other value refuse the provider's start alike, naming
  the variable and the admissible value.
- **Lab provisioning sets it**: `provision.sh` writes ConfigMap `srl-provider-settings` key
  `drift-policy=revertive` in `agentic-netops-system` before the provider is applied.
- **A production deployment states it itself and never inherits it** — `deploy/agentic-netops/`
  deliberately ships no `srl-provider-settings`, so a deployment that forgets it does not start.
- The value lands on **`spec.revertive: true` of every `Config`** the provider generates; no member
  of the set can produce `false` or an absent field. Drift on a managed path is restored by the
  device-configuration layer.
- **Why the layer's non-revertive mode is not admissible here.** It does **not** accept drift
  outright: it records the deviation and holds it for an operator to accept or revert. That is a
  shape the constitution would allow, and one this platform simply does not build — it has neither
  the `Ready=False` status shape a held deviation needs nor the path that clears one.
- **What admitting another value would take**: its repair procedure, its status shape, its tests and
  its own entry in this runbook — a change to FR-015, not a setting and **not a constitution
  amendment**.

**Steps.**

```bash
kubectl -n agentic-netops-system get configmap srl-provider-settings -o jsonpath='{.data.drift-policy}{"\n"}'
kubectl -n agentic-netops-system logs deploy/srl-provider | grep -m1 DRIFT_POLICY
# restore the lab value if it was changed or removed
kubectl -n agentic-netops-system patch configmap srl-provider-settings --type merge -p '{"data":{"drift-policy":"revertive"}}'
kubectl -n agentic-netops-system rollout restart deploy/srl-provider
```

**Expected.** `revertive`; the provider Running; every generated `Config` carries
`spec.revertive: true`.

**If it fails.** The provider still refuses: the log line names the value it read — anything but the
exact lower-case string `revertive` is refused. `make test-managed-drift` shows the policy acting.

**Evidence.** The provider's refusal or start-up log; `make test-managed-drift` (SC-007) asserts
what gate item G13 recorded about the layer's behaviour and nothing more.

---

## 10. Audit record

**When.** Someone asks who confirmed, submitted or removed a service; before any removal of the tier
or teardown (reconcile while both the store and the objects exist); after a removal (read the
exported file).

**Before you start.** Where it lives (FR-078): **in the agent-analytics store — ClickHouse,
StatefulSet `clickhouse` in `agentic-netops-agents` — not in Kubernetes Events.** Each audit event is
a span event named `audit.<type>` (`confirm`, `decline`, `submit`, `refuse`, `remove`,
`out_of_band`) on the request trace, in table `otel.otel_traces`, kept with no expiry. It carries the
principal (the authenticated username), correlation id, thread id, resources and, for submissions,
the submitted-spec hash. The deployer mirrors its three events as Kubernetes Events in
`agentic-netops-intent`; those expire and are never the record. A request refused for want of a
credential emits no audit event. The store's credentials (`clickhouse-auth`, generated) are used
from inside the pod only; they never reach the host.

**Steps — query it.**

```bash
kubectl -n agentic-netops-agents exec clickhouse-0 -c clickhouse -- bash -c \
  'clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" --query "
    SELECT toString(Timestamp) AS ts, TraceId AS correlation_id, e.1 AS event, e.2 AS attrs
    FROM otel.otel_traces ARRAY JOIN arrayZip(Events.Name, Events.Attributes) AS e
    WHERE startsWith(e.1, '\''audit.'\'') ORDER BY Timestamp FORMAT JSONEachRow"' | jq -c .
```

**Steps — reconcile it** (every `submit`/`remove` has a matching second confirmation, hashes match
the live objects, every principal is one of the run's usernames):

```bash
cd agents && AGENTIC_NETOPS_E2E=1 uv run pytest tests/e2e/test_audit_reconcile.py -v
```

**Steps — export it stand-alone** (writes the export and the usernames record, removes nothing):

```bash
CLUSTER_NAME=agentic-netops scripts/lib/audit_export.sh export
scripts/lib/audit_export.sh settings        # the effective database, tables, timeout
```

**Expected.** Files in the run's `EVIDENCE_DIR`
(`.evidence/agentic-netops_agentic-netops-fabric/<UTC run id>/`):
`audit-export-<attempt>.ndjson.gz` (one JSON object per stored row), `audit-export-<attempt>.json`
(its evidence record with hash and row count), `audit-export-<attempt>.stdout`
(`store_rows`, `rows_written`, `newest_row_timestamp`, tables), and
`operator-usernames-<attempt>.stdout` (the distinct usernames and `username_unchanged`). An empty
store exports an empty record; an absent store is skipped. A run that finds a verified earlier export
skips and records `audit-export-skip-<attempt>` instead (the rule is in §11).

**If it fails.** The export fails when the store does not answer within
`AUDIT_EXPORT_TIMEOUT_SECONDS` (120 s), when the query errors, when the artefact cannot be written,
or when fewer rows are written than the store reported. Check
`kubectl -n agentic-netops-agents get sts,po clickhouse-0` and its log; raise the timeout for a large
store; make the evidence directory writable. A removal stopped by a failed export leaves the store
intact — re-run it once fixed.

**Evidence.** The export files above are the record once the store is gone; read them back with the
file-source mode in §11.

---

## 11. Removing the intent tier

**When.** You want the lab without the tier — the control plane, the fabric and every service in
`agentic-netops-services` stay. (To destroy everything, use §2: a full teardown needs none of the
flags below and still exports the audit record first.)

**Before you start.**
- Run the live audit reconciliation (§10) now; afterwards only the exported file exists.
- Know what the removal does **not** remove: **the services the tier submitted** (the `Network`s in
  `agentic-netops-intent`). The removal lists them and **refuses while they exist**, having changed
  nothing. `--remove-services` is a word of its own because each of those services was created under
  two operator confirmations; `--purge-intent-tier` names the tier, not them.
- Services in `agentic-netops-services` are **not the tier's and are untouched** either way.
- Every target those services touch should be reachable: a removal stops on an unreachable one.

**Steps.**

```bash
# 1. without the flag: lists the tier's services and stops non-zero while any exist
./scripts/off.sh --purge-intent-tier; echo "exit=$?"
kubectl -n agentic-netops-intent get networks.fabric.agentic-netops.io

# 2. with it: deletes those services, then removes the tier
./scripts/off.sh --purge-intent-tier --remove-services

# 3. read the record back from the file — the store and operator-credentials are gone now
EXPORT=$(ls -t "$PWD"/.evidence/agentic-netops_*/*/audit-export-*.ndjson.gz | head -1)
cd agents && AGENTIC_NETOPS_E2E=1 uv run pytest tests/e2e/test_audit_reconcile.py -v --audit-export "$EXPORT"
```

What happens, in order (NFR-006, AD-24, AD-26, AD-35, AD-36, AD-46):
1. **The refusal list** — a read, through `evidence_run`, deciding only whether to go on. Any
   `Network` present and no `--remove-services`: stop non-zero, naming each and both continuations,
   **having changed nothing**.
2. **Scale-down** — the request-accepting workloads `supervisor`, `ui` and `deployer` go to zero
   replicas, so nothing new lands and no audit event is written after the export. This precedes the
   export on **every** path past the refusal, including the no-flag run over an empty list.
3. **The authoritative list** — taken after the scale-down. **Without** the flag, a non-empty list
   here (a service landed between the two lists) sends the removal back to the refusal: nothing
   deleted, nothing exported, the workloads left at zero — **re-provisioning
   (`provision.sh --with-intent-tier`) brings them back**.
4. **Audit-record export** and the usernames record, unconditionally, before anything removes the
   store or the operator Secret. A failed export stops the removal with the store intact.
5. The listed `Network`s deleted and their finalizers waited on for up to `TIER_PURGE_WAIT_SECONDS`
   (300 s). **Never force-released.**
6. Only once a re-list is empty: the workloads, the tier Secrets, the provisional claims, the borrowed
   claim Role, `deny-tier-force-release` and its binding, the dashboard patch, and the namespaces
   `agentic-netops-intent` and `agentic-netops-agents`. A second run is a no-op.

**Where the export lands.** `.evidence/agentic-netops_agentic-netops-fabric/<UTC run id>/audit-export-<attempt>.ndjson.gz`,
with `audit-export-<attempt>.json` (hash, row count) and the usernames record
`operator-usernames-<attempt>.stdout` beside it. The file-source mode (`--audit-export`) reads that
artefact and the usernames record **alone**; the stream half reconciles from them, and the
live-object half is reported "not run", never passed.

**The re-run rule** (data-model.md §16). A stopped removal is re-run with the same command. The
export step then **skips** — capturing the skip as `audit-export-skip-<attempt>` naming the artefact
relied on — when the lab's evidence root (`.evidence/<cluster>_<lab>/` and any operator-set
`EVIDENCE_DIR`) holds a **verified** export: its record has exit status 0 and rows written equal to
the store's count, its content hash is intact, **and** the store asked now reports the same row count
**and** the same newest-row timestamp. Otherwise it **adds** a new artefact under a new attempt id.
**It never rewrites one.**

**`--discard-audit-record`** lets the removal go past a **failed** export; the store is then removed
unexported. Its use is printed and recorded in the run's evidence. Use it only when the record is
knowingly abandoned.

**Expected.** Exit `0`; `kubectl get ns | grep -E 'agentic-netops-agents|agentic-netops-intent'`
prints nothing; `kubectl get validatingadmissionpolicy deny-tier-force-release` is `NotFound`; the
control-plane gates still pass with the tier absent — e.g. `make wait-fabric verify-fabric-control-plane wait-services verify-services` (NFR-006).

**If it fails.**
- *Refused, listing services* — expected without `--remove-services`. Either add the flag, or leave
  the tier in place.
- *Fell back to the refusal after the scale-down* — a service landed between the lists. The tier is
  scaled down; run `./scripts/provision.sh --cluster-name agentic-netops --with-intent-tier` to bring
  it back, or re-run with `--remove-services`.
- *Stopped, naming a `Network` still `Deleting` and its unreachable target* (or its holding service)
  — the rest of the tier stays in place, scaled down. **Wait**: restore the target and re-run; the
  finalizer completes and the re-run finishes. Or, for a device that will not return, **force-release
  by §4** and re-run. **Never a shortcut** — no deleting finalizers or claims by hand. The wait is not
  spent on a `Network` already `Deleting=True/TargetUnreachable` when it begins: that stops at once.
- *Export failed* — §10 **If it fails**; then re-run. Or `--discard-audit-record`, deliberately.

**Evidence.** The run's `EVIDENCE_DIR`: both lists, the scale-down, the export or the skip, the
usernames record, the deletions; `tests/e2e/tier_purge_live.sh` is the live proof of the refused,
blocked and completed paths.

---

## 12. VNI and service VLAN cannot be edited

**When.** A patch or apply of a `Network` is refused with a message that a field "is immutable once
the Network is accepted".

**Before you start.** Once a `Network` is accepted, `spec.bridgeDomains[].l2vni`,
`spec.routers[].l3vni`, `spec.vlans[].vlan` and `spec.bridgeDomains[].vlan` cannot change, and entries
of those lists cannot be added, removed or renamed (CEL on the CRD — AD-25). Changing one is a
**removal and a new service**, so no claim is ever superseded while its service lives. Attachments,
access lists, prefixes and gateway addresses stay editable.

**Steps.**

```bash
kubectl -n agentic-netops-services get networks.fabric.agentic-netops.io <name> -o yaml > /tmp/<name>.yaml
kubectl -n agentic-netops-services delete networks.fabric.agentic-netops.io <name>     # waits for the finalizer
# edit the identifier in /tmp/<name>.yaml, drop status/resourceVersion/uid, then
kubectl apply -f /tmp/<name>.yaml
```
For a tier-submitted service, ask the tier to remove it and to create the new one (two
confirmations each).

**Expected.** The delete completes after the removal is read back and the claims are released; the
new object is accepted with the new identifier.

**If it fails.** The delete blocks: §3 (`Deleting` condition). The new apply is refused
`AllocationConflict`: §17.

**Evidence.** The `Network`'s Events and conditions; the provider's claim records in
`status.claimRefs`.

---

## 13. Two VLAN bands

**When.** A request or a `Network` is refused naming a VLAN and two bands; you are choosing a VLAN.

**Before you start.** The rule (FR-062, AD-33):
- An **operator names only from `100–999`**.
- The **allocation authority allocates only from `1000–4000`** — its pool's minimum is 1000.
- The two bands are **disjoint, so a named VLAN can never collide with an allocated one**; nothing has
  to arbitrate between them.
- A VLAN in `1000–4000` on a `Network` must be backed by an adoptable claim. **The refusal of a named
  VLAN in `1000–4000` means that band is the authority's to hand out** — not that the value is taken.
  On the tier path the mapper refuses it at interpretation, before any claim; on a `Network` applied
  with `kubectl` it is `Accepted=False/AllocationConflict`. An `ip-vrf` attachment never gets an
  allocated VLAN, so one in `1000–4000` is always refused. The VLAN a standalone `acl` names is a
  reference to another service's subinterface and is never refused for its band.

**Steps.** Name a VLAN in `100–999`, or name none and let the tier allocate one:

```bash
kubectl -n agentic-netops-services get networks.fabric.agentic-netops.io <name> \
  -o jsonpath='{range .status.conditions[?(@.type=="Accepted")]}{.status}/{.reason}: {.message}{"\n"}{end}'
kubectl -n agentic-netops-allocation get identifierclaims -l agentic-netops.io/correlation-id=<id>   # allocated ones, 1000–4000
```

**Expected.** A VLAN in `100–999` is accepted (subject to the one-owner rule per node, port and VLAN);
an allocated one reads `1000–4000` in `status.claimRefs`.

**If it fails.** A named VLAN in `100–999` refused naming another service: that (node, port, VLAN) is
already owned — choose another.

**Evidence.** The refusal message; the claims listed above.

---

## 14. grafana-admin credential

**When.** Logging in to Grafana; rotating its administrator password.

**Before you start.** Secret `grafana-admin` in `monitoring`, generated by the lab-secret step at
`TargetsReady` (whether or not the tier is installed): keys `admin-user` (default `admin`,
`GRAFANA_ADMIN_USER` overrides) and `admin-password`, **always generated**, never a literal in a
manifest. Grafana runs with anonymous access disabled and sign-up disabled: there is **no anonymous
and no default login** (FR-096). The password is preserved on re-provisioning and removed by
`off.sh`.

**Steps.**

```bash
kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-user}' | base64 -d; echo
kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d; echo
kubectl -n monitoring port-forward svc/grafana 3000:3000     # then http://127.0.0.1:3000
```
To rotate: the generator preserves an existing Secret, so delete it and re-run provisioning (its
`TargetsReady` step re-creates it with a new password), then restart Grafana — its database is an
`emptyDir`, so every start creates the administrator afresh from the Secret:

```bash
kubectl -n monitoring delete secret grafana-admin
./scripts/provision.sh --cluster-name agentic-netops --with-intent-tier
kubectl -n monitoring rollout restart deploy/grafana
```

**Expected.** The login form, and only the generated pair logs in.

**If it fails.** Login refused after a rotation — Grafana still has the previous pair; restart it.

**Evidence.** None is written for the value, by design; the Secret's presence is checked by
provisioning.

---

## 15. Who releases a claim

**When.** Claims carrying a removed service's correlation label are still bound; you want to know
whether an identifier is free; a claim looks orphaned.

**Before you start.** One release owner per claim (FR-109, AD-32):
- **The tier** releases a claim **only while it is provisional** — on a decline, on rollback of a
  failed submission, or for a request never submitted — and **only for the correlation ids the
  deployer names as releasable** (those whose `Network` does not exist). The allocator never reads a
  `Network`; it deletes what it is told to.
- **The provider** owns every claim **after submission**: it adopts the tier's claims (label,
  deterministic name and value must all agree) or creates its own, and releases them **at
  finalization, after the removal is read back** from every device. A held deletion holds them.
- **An adopted claim stays held even after its value leaves the object** — adoption is decided once
  per value; removing the attachment that carried an allocated VLAN does not release it before
  finalization.
- **Never delete a claim by hand.**

**Steps — read `status.claimRefs`.**

```bash
kubectl -n agentic-netops-intent get networks.fabric.agentic-netops.io <name> -o jsonpath='{.status.claimRefs}' | jq
kubectl -n agentic-netops-allocation get identifierclaims -l agentic-netops.io/correlation-id=<id>
make show-allocations
```
Each entry has five fields: `name` (the claim, `<namespace>.<name>.<role>`), `namespace` (where the
claim lives), `indexKind` (the VLAN index or the VNI index), `value`, and `origin` — `adopted` (the
tier made it) or `created` (the provider did); written once, never changed.

**Expected.** While a `Network` exists, its claims are listed and bound. After it is gone, a
claim-selector query on its correlation label is empty.

**If it fails.** Claims still bound after the service "went away": the `Network` is still finalizing
— read its `Deleting` condition (§3); with a device unreachable it holds them by design (§4).

**Evidence.** `status.claimRefs`; the authority's claim objects; `make test-provider-claims` (SC-045)
and the tier's claim-lifecycle suite (SC-046).

---

## 16. One tagging mode per port refusal

**When.** A request or a `Network` is refused naming a port and two services, for its tagging mode;
or refused listing ports for the tagging mode it asked for.

**Before you start.** Tagging is a property of the port, not of the service (FR-034). The `Fabric`
inventory declares each access port's mode: **tagged unless listed in that node's
`spec.inventory[].untaggedAccessPorts`**. An untagged attachment is admitted only on a declared
untagged port, a tagged one only on a port that is not; and an untagged and a tagged attachment can
never share a port. The refusal message names the port and **both services**:
`port <node> <port>: Network <a> asks for a <mode> attachment while Network <b> holds a <mode> one; tagging is a property of the port, one tagging mode per port`.

**Steps.**

```bash
kubectl -n agentic-netops-system get fabrics.fabric.agentic-netops.io fabric01 \
  -o jsonpath='{range .spec.inventory[*]}{.node}: untagged={.untaggedAccessPorts}{"\n"}{end}'
```
Then: name a VLAN on both services (tagged), or use a port the inventory declares untagged, or a
different port.

**Expected.** The corrected request or `Network` is accepted; nothing was created by the refused one.

**If it fails.** The port you need untagged is not declared so: that is a `Fabric` design change
(`untaggedAccessPorts`), made by the platform owner, not per service.

**Evidence.** The refusal message (webhook or the tier's pre-flight); zero objects created.

---

## 17. Network applied with kubectl: VNI claims and AllocationConflict

**When.** You applied a `Network` with `kubectl` (in `agentic-netops-services`) and it reports
`Accepted=False/AllocationConflict`, or you want to know which VNIs it claimed.

**Before you start.** Nobody claimed the VNIs a hand-applied `Network` names, so **the provider
does, before it renders any `Config`** (FR-109): one claim per stated VNI, for exactly that value, in
the VNI index, named `<namespace>.<name>.l2vni-<bridgeDomain>` or
`<namespace>.<name>.l3vni-<router>`. It never picks another value for you.
`AllocationConflict` means **the value is held by another owner, or lies outside the band**
(10000–20000 by default); the message **names the value and the holder or the band**, and **zero
`Config`s** exist. A VLAN in `1000–4000` needs an adoptable claim — which a hand-applied object does
not have — so it is the same refusal (§13).

**Steps.**

```bash
kubectl apply -f examples/constructs/macvrf.yaml
kubectl -n agentic-netops-services get networks.fabric.agentic-netops.io -o wide
kubectl -n agentic-netops-services get networks.fabric.agentic-netops.io <name> \
  -o jsonpath='{range .status.conditions[?(@.type=="Accepted")]}{.status}/{.reason}: {.message}{"\n"}{end}'
kubectl -n agentic-netops-services get networks.fabric.agentic-netops.io <name> -o jsonpath='{.status.claimRefs}' | jq
kubectl -n agentic-netops-allocation get identifierclaims -l agentic-netops.io/network-name=<name>
```

**Expected.** `Accepted=True`, one `created` claim per VNI in `status.claimRefs`, then the `Config`s.

**If it fails.** `AllocationConflict`: choose a free VNI inside the band (and a VLAN in `100–999`),
delete and re-apply (§12 — identifiers are immutable). A `Network` that sits un-accepted **without**
`AllocationConflict`, or a deletion stuck at `Deleting=True/RemovingConfiguration` naming the
authority: the authority is erroring or unreachable — a wait, never an answer; check
`kubectl -n agentic-netops-allocation get deploy,pods` and it completes when the authority answers.

**Evidence.** `make test-provider-claims` (SC-045) proves both the VNI and the VLAN refusal with zero
`Config`s.

---

## 18. Structured logs and following a correlation id

**When.** Tracing one request across the tier and the provider; explaining what the agents did.

**Before you start.** Every first-party workload writes **one JSON object per line** to standard
output (NFR-014, data-model.md §27): `ts` (UTC, RFC 3339), `level` (`debug`/`info`/`warn`/`error`),
`component` (`srl-provider`, `intent-translator`, `supervisor`, `mapper`, `allocator`, `deployer`),
`msg`, `kind`/`namespace`/`name` of the resource when there is one, `correlation_id` (every line of a
request, and every provider line about an object carrying the correlation label), and `thread_id`
(tier only). Values pass the credential redaction first. The correlation id is the **trace id** of the
request's trace, and the label `agentic-netops.io/correlation-id` on every `Network` and claim the tier
created. A log line is an aid; the outcome is always in a condition, an Event or a metric.

**Steps.**

```bash
kubectl -n agentic-netops-intent get networks.fabric.agentic-netops.io -L agentic-netops.io/correlation-id
CID=<32-hex correlation id>
kubectl -n agentic-netops-system logs deploy/srl-provider --since=2h \
  | jq -R -c --arg c "$CID" 'fromjson? | select(.correlation_id==$c)'
for d in supervisor mapper allocator deployer; do
  kubectl -n agentic-netops-agents logs deploy/$d --all-containers --since=2h \
    | jq -R -c --arg c "$CID" 'fromjson? | select(.correlation_id==$c)'
done | jq -s -c 'sort_by(.ts)[]'
kubectl -n monitoring port-forward svc/grafana 3000:3000     # http://127.0.0.1:3000/d/intent-tier?var-correlation_id=<CID>
```
The deployer's `--all-containers` includes the translator sidecar (`intent-translator`). In Grafana,
the intent-tier dashboard filtered on the correlation id shows the per-stage trace (the trace id is the
same value); the EVPN service-path dashboard links a service back to the conversation that created it.

**Expected.** One ordered story: supervisor → mapper → allocator → deployer (translator) → provider
lines for the resulting `Network`, all with the same `correlation_id`.

**If it fails.** No provider lines: the `Network` lacks the correlation label (applied with `kubectl`)
— follow it by `kind`/`namespace`/`name` instead. Missing tier lines past the pod's retention: the trace
in the analytics store (§10) keeps them.

**Evidence.** The trace in the analytics store (`otel.otel_traces`, `TraceId` = correlation id);
`make verify-metrics` checks the pipeline.

---

## 19. Host requirements

**When.** Choosing a host; the preflight refuses on resources; devices boot slowly or restart;
someone wants a throughput figure.

**Before you start.** Requirements (NFR-004, NFR-011, NFR-012):
- Linux x86-64, CPU exposing **SSSE3**, kernel **≥ 4.10**; no hypervisor, nested virtualization or
  acceleration device required (a hypervisor guest needs a host-passthrough CPU model for SSSE3).
- Docker with privileged containers; the tooling at the versions `versions.lock.yaml` pins.
- **Budget ≈2 vCPU and 2 GiB per SR Linux node** (four nodes), plus two endpoint containers, plus the
  Kind cluster's own budget (preflight default 4 vCPU / 6 GiB), plus, for the tier, the sum of the
  requests its manifests declare (`scripts/lib/intent_tier.sh requests`). The preflight refuses
  before anything is created, naming the shortfall.
- **Measured per-node footprint** (T052, idle after convergence: `Fabric` Ready, no `Network`; five
  samples 10 s apart from each container's cgroup), from
  `.evidence/agentic-netops_agentic-netops-fabric/20260921T115335Z/footprint.summary.stdout`, produced
  by `tests/integration/footprint.sh`:

  | Node | RSS mean (MiB) | CPU mean (% of one CPU) |
  |---|---|---|
  | leaf01 | 1342.3 | 6.4 |
  | leaf02 | 1343.2 | 6.3 |
  | spine01 | 1338.8 | 6.5 |
  | spine02 | 1340.6 | 6.4 |

  That is idle; convergence and services add to it, which is why the budget stays at 2 GiB per node.
- **Dataplane packet-rate ceiling**: **1000 PPS documented** for the unlicensed SR Linux container;
  **~5 kpps measured in research** (platform-coupling.md PC-S-10) — documented / measured in research,
  not re-observed by this platform's runs. Tests therefore assert reachability, isolation and counter
  movement, **never throughput**. Unlicensed containers also restart weekly.
- Access: both surfaces require an **authenticated operator** (FR-102, §5); the supervisor and the
  chat surface listen on `127.0.0.1` only.
- A **deletion blocks while a target is unreachable** (FR-103): a host that loses a device container
  leaves its services' removals held until the device returns or is force-released (§4).

**Steps.**

```bash
grep -m1 -ow ssse3 /proc/cpuinfo; uname -r; nproc; free -m
scripts/lib/intent_tier.sh requests
tests/integration/footprint.sh      # re-measure on your host (precondition: Fabric Ready, no Network)
```

**Expected.** The preflight's resource line reports available ≥ required. A re-measure writes its
own `footprint.summary` for your host.

**If it fails.** Free host memory or CPU, or run without the tier; never lower the preflight
thresholds to make a run pass.

**Evidence.** The T052 footprint file cited above; your own re-measure's `EVIDENCE_DIR`; the
preflight's resource line in each provisioning run's log.
