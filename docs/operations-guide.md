# Operations guide — running the platform day to day

## Runbook standard

| | |
|---|---|
| **Audience** | The operator who keeps a provisioned lab running: brings it up and down, holds its secrets, sets its bounds, watches drift, the audit record, observability and the host. |
| **Scope** | Day-to-day operation. Every topic of the one runbook standard is stated here with its key facts and the everyday commands; the complete incident procedure for each is in `docs/runbook.md` under the same topic number. |
| **Assumes** | A host that meets §19; the repository checked out; `kubectl`, `jq`, `docker`, `kind`, `containerlab`, `uv` on `PATH`; the context `kind-agentic-netops` selected; default names (cluster `agentic-netops`, lab `agentic-netops-fabric`, `Fabric` `fabric01`, management network `agentic-netops-mgmt` on `172.25.25.0/24`). |
| **Does not assume** | That anything here was observed on your lab. **Expected** lines state what the specification requires; what a run did is in its evidence under `.evidence/<cluster>_<lab>/<UTC run id>/`. |

**The four-document map.**

| Document | What it is for |
|---|---|
| `TUTORIAL.md` | The first bring-up, walked through end to end. |
| `docs/operator-guide.md` | Asking for services through the intent tier and reading what it reports. |
| `docs/operations-guide.md` (this file) | Running the platform day to day: secrets, bounds, drift, audit, observability, host. |
| `docs/runbook.md` | Incident procedures, each complete. |

`README.md` is written separately (T164) and is not one of the four.

**Procedure shape**, the same in all four documents: **When** · **Before you start** · **Steps**
(fenced commands, from the repository root) · **Expected** · **If it fails** · **Evidence**.

**Vocabulary.** Services are one of four constructs: `vlan`, `mac-vrf`, `ip-vrf`, `acl`.

---

## 1. Bring-up

**When.** A fresh host, after a teardown, or any time you want the lab converged (the script is
idempotent: no cluster recreation, no release churn, no unchanged device configuration reissued).

**Before you start.** §19 host checks; model-provider inputs in the environment if the tier is
wanted (§6); a free `MGMT_CIDR`.

**Steps.**

```bash
MGMT_CIDR=172.25.25.0/24 ./scripts/provision.sh --cluster-name agentic-netops --with-intent-tier
```
One script, one path, phases in this order: `NetworkReady` → `ClusterReady` → `LabReady` →
`AppsReady` → `TargetsReady` → `GateReady` → `FabricReady` → `ObservabilityReady` →
`IntentTierReady` (the last only with `--with-intent-tier`). No flag skips or reorders a phase or a
gate; the allocation authority is the lock file's `allocationAuthority.kind`, never a flag.

**Expected.** Exit `0`; `fabric01` `Ready=True`; with the tier, the supervisor on
`127.0.0.1:19090` and the chat surface on `127.0.0.1:13000`:

```bash
kubectl -n agentic-netops-system get fabrics.fabric.agentic-netops.io fabric01
curl -s 127.0.0.1:19090/v1/health | jq
```

**If it fails.** The script names the phase — §3, and `docs/runbook.md` §3 for each phase.

**Evidence.** The run's `EVIDENCE_DIR`; `make verify-evidence`. Full procedure and the phase table:
`docs/runbook.md` §1.

---

## 2. Teardown

**When.** Ending a lab or rebuilding from clean.

**Before you start.** With the tier up, reconcile the audit record first (§10).

**Steps.**

```bash
./scripts/off.sh --cluster-name agentic-netops                     # add --preserve-evidence for a teardown-time capture
```

**Expected.** Exit `0`; a second run is a no-op; only resources labelled
`agentic-netops.io/owned-by=agentic-netops` are removed; images are kept. The audit record is
exported first whenever the analytics store exists. **The evidence root `.evidence/<cluster>_<lab>/`
is never deleted** — by `off.sh`, the full teardown or the tier's removal, with or without
`--preserve-evidence`, which only *adds* a capture.

**If it fails.** A present-but-unowned resource refuses the whole run with nothing deleted. A failed
audit export stops with the store intact; `--discard-audit-record` goes past it and is recorded.

**Evidence.** The run's `EVIDENCE_DIR`. Full procedure: `docs/runbook.md` §2.

---

## 3. Per-stage failure diagnosis

**When.** `provision.sh` stopped, or a Ready object is not.

**Before you start.** Read the named phase and the last `ERROR` lines.

**Steps — where to look first, per phase.**

| Phase | Look at |
|---|---|
| `NetworkReady` | `make verify-pins`; the preflight message (CIDR collision named, SSSE3, kernel ≥ 4.10, vCPU/memory shortfall) |
| `ClusterReady` | `kind get clusters`; `docker network inspect agentic-netops-mgmt` |
| `LabReady` | `containerlab inspect -t lab/topology.clab.yml`; device memory (§19) |
| `AppsReady` | cert-manager, the authority (`kubectl -n agentic-netops-allocation get deploy,pods`), **G11** (`$EVIDENCE_DIR/g11-observations.json`), `sdc-system`, the provider's log |
| `TargetsReady` | `kubectl -n agentic-netops-system get targets.config.sdcio.dev`; `make wait-targets` |
| `GateReady` | `kubectl -n agentic-netops-system get configmap fabric-qualification -o yaml`; `tests/gate/observed/` |
| `FabricReady` | `fabric01` conditions; `make verify-fabric-control-plane`; `make show-bgp` |
| `ObservabilityReady` | `kubectl -n monitoring get pods`; `make wait-observability` |
| `IntentTierReady` | `scripts/lib/intent_tier.sh requests`; `make test-boundary`; `kubectl -n agentic-netops-agents get po` |

```bash
kubectl -n agentic-netops-system get fabrics.fabric.agentic-netops.io fabric01 \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status}/{.reason}: {.message}{"\n"}{end}'
```

**Expected.** The condition or the refusal names the cause; no gate is ever skipped or weakened to get
past it.

**If it fails.** Symptom table: `docs/runbook.md` §3 and quickstart.md §"Diagnosing a failure".

**Evidence.** The failing run's `EVIDENCE_DIR`.

---

## 4. Force-release procedure

**When.** Only for a `Network` being deleted and stuck at `Deleting=True/TargetUnreachable` on a device
that **will not return**. A device that is merely away needs nothing: restore it and the removal
completes itself; there is no timeout.

**Before you start.** A non-empty reason (empty is refused). Accept that configuration **may be
orphaned on the unreachable device**. Use cluster tooling as an operator: the tier's identities are
denied the annotation at admission by `deny-tier-force-release`.

**Steps.**

```bash
kubectl -n <ns> annotate networks.fabric.agentic-netops.io <name> \
  fabric.agentic-netops.io/force-release="<device> decommissioned, ticket <id>"
kubectl -n agentic-netops-system get fabrics.fabric.agentic-netops.io fabric01 -o jsonpath='{.status.findings}' | jq
```

**Expected.** Honoured only on a deleting object blocked on `TargetUnreachable`; anywhere else it is
**ignored with a `Warning` Event** (`ForceReleaseIgnored`) and nothing is released. Honoured: a
finding in `Fabric.status.findings[]` and a `Warning` Event `ForceReleased`, then the claims released
and the object gone. When the device returns, the `Fabric` reports
`Degraded=True/StaleConfigurationPossible`; **the finding clears only after a clean scheduled
read-back** shows the named objects absent.

**If it fails.** The Event names why it was ignored or refused.

**Evidence.** The Events and `status.findings[]`. Full procedure: `docs/runbook.md` §4.

---

## 5. Operator credentials

**When.** Logging in, a `401`, rotation.

**Before you start.** Secret `operator-credentials` in `agentic-netops-agents`: `username` (default
`operator`, `OPERATOR_USERNAME`) and an always-generated `password`. **Lab credentials over loopback
HTTP Basic — not production-safe.** Every route but `/health` and `/v1/health` requires them.

**Steps.**

```bash
OP_USER=$(kubectl -n agentic-netops-agents get secret operator-credentials -o jsonpath='{.data.username}' | base64 -d)
OP_PASS=$(kubectl -n agentic-netops-agents get secret operator-credentials -o jsonpath='{.data.password}' | base64 -d)
# rotate the password: remove it, let the generator write a new one (provisioning preserves an existing one)
kubectl -n agentic-netops-agents patch secret operator-credentials --type json -p '[{"op":"remove","path":"/data/password"}]'
CLUSTER_NAME=agentic-netops scripts/lib/intent_secrets.sh operator-credentials
```

**Expected.** The supervisor re-reads the mounted file — **no restart** — once the kubelet has synced
it; the old password then gets `401`.

**If it fails.** Wait for the sync and re-read the Secret.

**Evidence.** `operator-username-<attempt>` in each provisioning run (never the password). Full
procedure: `docs/runbook.md` §5.

---

## 6. Model-provider Secret

**When.** Choosing or switching the model provider, declaring a gateway, changing or clearing the
base URL.

**Before you start.** Secret `llm-provider` in `agentic-netops-agents`, from
`AGENTIC_NETOPS_LLM_MODEL`, `AGENTIC_NETOPS_LLM_API_KEY`, `AGENTIC_NETOPS_LLM_BASE_URL`,
`AGENTIC_NETOPS_LLM_GATEWAY` (keys `LLM_MODEL`, `API_KEY`, `BASE_URL`, `GATEWAY`). **Declaring a
gateway requires a base URL** — refused otherwise, before any tier workload exists. **The base URL is
preserved on re-provisioning because the Secret is merged**: an input you leave unset keeps its stored
value. Clear it only with `AGENTIC_NETOPS_LLM_BASE_URL_CLEAR=1`. The endpoint is printed **redacted**
(FR-106).

**Steps — always a merge patch, never a whole-object replace.**

```bash
kubectl -n agentic-netops-agents patch secret llm-provider --type merge \
  -p '{"stringData":{"LLM_MODEL":"<prefix>/<model>","API_KEY":"<key>"}}'
AGENTIC_NETOPS_LLM_BASE_URL_CLEAR=1 ./scripts/provision.sh --cluster-name agentic-netops --with-intent-tier   # clear the base URL
```
Never `kubectl replace`, or `kubectl apply` of a full Secret: every key it omits — the base URL
first — is deleted.

**Expected.** Agents read the mounted Secret on every model call; their start-up log names the
redacted endpoint.

**If it fails.** A gateway refusal names the missing base URL; model-call failures name the model
dependency.

**Evidence.** The provisioning line `llm-provider: model calls will go to …`. Full procedure:
`docs/runbook.md` §6.

---

## 7. lastVerifiedTime and the stalled re-verification alert

**When.** Daily health check; the `ReverificationStalled` alert.

**Before you start.** `status.lastVerifiedTime` on every `Fabric` and `Network` **advances on every
re-verification pass that ran, whatever it found** (a pass that sets `Ready=False` still ran). A pass
that cannot run sets `Ready=Unknown` and `Degraded=True`, reason `VerificationFailed`, naming the
target — not a success and not a failure — and the timestamp stops. `ReverificationStalled` fires when
`time() - reverify_last_success_timestamp_seconds` exceeds **one re-verification interval plus one
reconciliation interval** (FR-107).

**Steps.**

```bash
kubectl get networks.fabric.agentic-netops.io -A \
  -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,VERIFIED:.status.lastVerifiedTime
kubectl get --raw '/api/v1/namespaces/monitoring/services/prometheus:9090/proxy/api/v1/alerts' | jq '.data.alerts[].labels.alertname'
```

**Expected.** Every timestamp within one interval (5 min default) of now; no stalled alert.

**If it fails.** Restore the named target's management reachability; the next pass settles it.

**Evidence.** `make test-reverify` (SC-044). Full procedure: `docs/runbook.md` §7.

---

## 8. Default bounds

**When.** Tuning, testing, or explaining a timeout.

**Before you start.** data-model.md §25 — one default each, one environment variable each:

| Bound | Default | Variable (owner) |
|---|---|---|
| Reconciliation interval | 15 s | `RECONCILE_INTERVAL` (provider) |
| Transient-error backoff | 250 ms base, 10 s cap, 6 attempts, full jitter | `RETRY_BACKOFF_BASE`, `RETRY_BACKOFF_CAP`, `RETRY_MAX_ATTEMPTS` (provider) |
| Re-verification interval | 5 min, **floor 30 s** (below it or unparseable: the provider refuses to start) | `REVERIFY_INTERVAL` (provider) |
| Iteration limit | 3 | `SUPERVISOR_MAX_ITERATIONS` (supervisor) |
| Request deadline | 300 s | `SUPERVISOR_REQUEST_DEADLINE_SECONDS` (supervisor) |
| Worker call timeout | 60 s | `WORKER_CALL_TIMEOUT_SECONDS` (supervisor) |
| Deployer call timeout | 210 s | `DEPLOYER_CALL_TIMEOUT_SECONDS` (supervisor) |
| Worker call retries | 2 (1 s, 2 s) | `WORKER_CALL_RETRIES` (supervisor) |
| Convergence timeout | 150 s | `DEPLOYER_CONVERGENCE_TIMEOUT_SECONDS` (deployer) |
| Allocation-authority retry | worker-call rule, then a named failure | allocator agent |
| Tier-removal wait | 300 s | `TIER_PURGE_WAIT_SECONDS` (`off.sh`) |
| Audit-record export | 120 s | `AUDIT_EXPORT_TIMEOUT_SECONDS` (`off.sh`) |

Start-up asserts convergence < deployer call < request deadline ≤ 5 min. A deletion held on an
unreachable target has no bound.

**Steps — override.**

```bash
kubectl -n agentic-netops-system patch configmap srl-provider-settings --type merge -p '{"data":{"reverify-interval":"2m"}}'
kubectl -n agentic-netops-system rollout restart deploy/srl-provider
kubectl -n agentic-netops-agents set env deploy/supervisor WORKER_CALL_TIMEOUT_SECONDS=90   # durable: deploy/agents/*.yaml, then re-provision
TIER_PURGE_WAIT_SECONDS=600 ./scripts/off.sh --purge-intent-tier --remove-services
```

**Expected.** The workload starts with the new value, or refuses naming the variable.

**If it fails.** Remove the override to return to the default.

**Evidence.** Start-up logs; `agentic_netops_reverify_interval_seconds` in Prometheus. Full
procedure: `docs/runbook.md` §8.

---

## 9. Drift policy

**When.** Checking the lab's drift behaviour; preparing a non-lab deployment; the provider refuses to
start naming `DRIFT_POLICY`.

**Before you start.** `DRIFT_POLICY` has **no default** and a **closed value set of one: `revertive`**.
Anything else — unset and empty included — makes the provider refuse to start. **Lab provisioning sets
it** (ConfigMap `srl-provider-settings`, key `drift-policy`, in `agentic-netops-system`); **a production
deployment states it itself and never inherits it** — `deploy/agentic-netops/` ships no value. It lands
as `spec.revertive: true` on every generated `Config`. The device-configuration layer's non-revertive
mode is **not admissible here**: it does not accept drift outright — it records the deviation and holds
it for an operator to accept or revert. That is a shape the constitution would allow and this platform
does not build: it has neither the `Ready=False` status shape a held deviation needs nor the path that
clears one. Admitting another value would take its repair procedure, its status shape, its tests and its
own runbook entry — a change to FR-015, not a constitution amendment (AD-17, AD-34).

**Steps.**

```bash
kubectl -n agentic-netops-system get configmap srl-provider-settings -o jsonpath='{.data.drift-policy}{"\n"}'
make test-managed-drift
```

**Expected.** `revertive`; managed-path drift restored.

**If it fails.** Restore `drift-policy=revertive` and restart the provider — `docs/runbook.md` §9.

**Evidence.** `make test-managed-drift` (SC-007).

---

## 10. Audit record

**When.** Answering who did what through the tier; before any removal or teardown.

**Before you start.** The record lives in the **analytics store — ClickHouse (`clickhouse-0`) in
`agentic-netops-agents`** — as `audit.*` span events in `otel.otel_traces`, not in Kubernetes Events
(those are a short-lived mirror). Credentials stay inside the pod (FR-078).

**Steps.**

```bash
# query
kubectl -n agentic-netops-agents exec clickhouse-0 -c clickhouse -- bash -c \
  'clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" --query "
    SELECT toString(Timestamp), TraceId, e.1 FROM otel.otel_traces
    ARRAY JOIN arrayZip(Events.Name, Events.Attributes) AS e
    WHERE startsWith(e.1, '\''audit.'\'') ORDER BY Timestamp"'
# reconcile against live objects
cd agents && AGENTIC_NETOPS_E2E=1 uv run pytest tests/e2e/test_audit_reconcile.py -v
# export stand-alone (removes nothing)
CLUSTER_NAME=agentic-netops scripts/lib/audit_export.sh export
```

**Expected.** `audit-export-<attempt>.ndjson.gz`, its record, and `operator-usernames-<attempt>.stdout`
in the run's `EVIDENCE_DIR`.

**If it fails.** Store unanswering within `AUDIT_EXPORT_TIMEOUT_SECONDS`, a query error, an unwritable
directory or a short row count — `docs/runbook.md` §10.

**Evidence.** The export is the record once the store is gone.

---

## 11. Removing the intent tier

**When.** You want the control plane and the fabric without the tier.

**Before you start.** Removing the tier does **not** remove the services it submitted: the removal
**lists them and refuses while they exist**, changing nothing. `--remove-services` — a word of its
own, because each service was created under two confirmations — deletes them, then the namespace goes.
Services in `agentic-netops-services` are untouched either way. A full teardown (§2) destroys the
environment and needs no such flag. Reconcile the audit record first (§10).

**Steps.**

```bash
./scripts/off.sh --purge-intent-tier                       # lists and refuses while tier services exist
./scripts/off.sh --purge-intent-tier --remove-services     # removes them, then the tier
EXPORT=$(ls -t "$PWD"/.evidence/agentic-netops_*/*/audit-export-*.ndjson.gz | head -1)
cd agents && AGENTIC_NETOPS_E2E=1 uv run pytest tests/e2e/test_audit_reconcile.py -v --audit-export "$EXPORT"
```

**Expected.** The request-accepting workloads `supervisor`, `ui`, `deployer` are **scaled down first**;
the audit record is **exported after the scale-down on every path past the refusal**, with the
usernames record beside it, to `.evidence/agentic-netops_agentic-netops-fabric/<UTC run id>/`; the
services deleted and waited on up to `TIER_PURGE_WAIT_SECONDS` (300 s), never force-released; then the
tier's namespaces, Secrets, claims and `deny-tier-force-release` removed. The file-source read-back
(`--audit-export`) reconciles the stream from the file alone. A re-run **skips** the export when a
verified one exists (exit 0, rows = store count, same newest-row timestamp, hash intact) and **adds** a
new attempt otherwise — never rewrites (data-model.md §16). `--discard-audit-record` goes past a
failed export, and its use is recorded.

**If it fails.** Without the flag, a service landing between the two lists sends the removal back to
the refusal with the workloads left scaled down — **re-provisioning (`provision.sh
--with-intent-tier`) brings them back**. Stopped on an unreachable target: **wait** and re-run, or
**force-release by §4** — never a shortcut.

**Evidence.** The run's `EVIDENCE_DIR`. Full procedure: `docs/runbook.md` §11.

---

## 12. VNI and service VLAN cannot be edited

**When.** A change to a `Network`'s VNI or service VLAN is refused as immutable.

**Before you start.** After acceptance, `bridgeDomains[].l2vni`, `routers[].l3vni`, `vlans[].vlan` and
`bridgeDomains[].vlan` are immutable (CEL, AD-25). The change is a removal and a new service.

**Steps.**

```bash
kubectl -n agentic-netops-services delete networks.fabric.agentic-netops.io <name>
kubectl apply -f <edited manifest>
```

**Expected.** The old service's claims released after read-back; the new one accepted.

**If it fails.** Deletion held: §3; new one refused: §17.

**Evidence.** Conditions and `status.claimRefs`. Full procedure: `docs/runbook.md` §12.

---

## 13. Two VLAN bands

**When.** Picking a VLAN, or a refusal naming a VLAN and two bands.

**Before you start.** Operators name only from **`100–999`**; the authority allocates only from
**`1000–4000`**. The bands are disjoint, so a named and an allocated VLAN **cannot collide**. A refusal
of a named VLAN in `1000–4000` means that band is the authority's to hand out — **name one in
`100–999` or let the tier allocate** (FR-062, AD-33).

**Steps.**

```bash
kubectl -n agentic-netops-allocation get identifierclaims -l agentic-netops.io/correlation-id=<id>
```

**Expected.** Allocated values in `1000–4000`, named ones in `100–999`.

**If it fails.** A `100–999` VLAN refused naming another service is already owned on that port.

**Evidence.** The refusal and the claims. Full procedure: `docs/runbook.md` §13.

---

## 14. grafana-admin credential

**When.** Logging in to Grafana.

**Before you start.** Secret `grafana-admin` in `monitoring`, generated at `TargetsReady` —
`admin-user` (default `admin`) and an always-generated `admin-password`. Anonymous access is disabled
and there is **no default login** (FR-096).

**Steps.**

```bash
kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d; echo
kubectl -n monitoring port-forward svc/grafana 3000:3000     # http://127.0.0.1:3000
```

**Expected.** Only the generated pair logs in.

**If it fails.** Rotation and restart: `docs/runbook.md` §14.

**Evidence.** None for the value, by design.

---

## 15. Who releases a claim

**When.** Wondering whether an identifier is free, or why a claim is still bound.

**Before you start.** **The tier** releases a claim only while it is provisional (decline, rollback,
never submitted) and only for the correlation ids **the deployer names**. **The provider** holds and
releases everything after submission, **at finalization, after the removal is read back**. An
**adopted claim stays held even after its value leaves the object**, until finalization. Never delete a
claim by hand (FR-109, AD-32).

**Steps.**

```bash
kubectl -n <ns> get networks.fabric.agentic-netops.io <name> -o jsonpath='{.status.claimRefs}' | jq
```
Each entry: `name`, `namespace`, `indexKind`, `value`, `origin` (`adopted` | `created`).

**Expected.** Claims listed while the object lives; none left after it is gone.

**If it fails.** Still bound after deletion: the `Network` is still finalizing — `docs/runbook.md` §15.

**Evidence.** `status.claimRefs`; the authority's claims.

---

## 16. One tagging mode per port refusal

**When.** A refusal naming a port and two services for its tagging mode.

**Before you start.** Tagging is a property of the port (FR-034). A port is tagged unless the `Fabric`
inventory lists it in `untaggedAccessPorts`; an untagged and a tagged attachment cannot share it. The
message names the port and both services.

**Steps.**

```bash
kubectl -n agentic-netops-system get fabrics.fabric.agentic-netops.io fabric01 \
  -o jsonpath='{range .spec.inventory[*]}{.node}: {.untaggedAccessPorts}{"\n"}{end}'
```

**Expected.** Use a VLAN on both, or a declared untagged port, or another port.

**If it fails.** A needed untagged port is a `Fabric` design change.

**Evidence.** The refusal; nothing created. Full procedure: `docs/runbook.md` §16.

---

## 17. Network applied with kubectl: VNI claims and AllocationConflict

**When.** Applying `Network`s by hand into `agentic-netops-services`.

**Before you start.** The provider claims each stated `l2vni`/`l3vni` as
`<ns>.<name>.l2vni-<bridgeDomain>` / `<ns>.<name>.l3vni-<router>` **before any `Config`**.
`AllocationConflict` = the value is held by another owner or outside the band (10000–20000 by default);
the message names the value and the holder or the band, and **zero `Config`s** exist. A VLAN in
`1000–4000` needs an adoptable claim, which a hand-applied object lacks (FR-109).

**Steps.**

```bash
kubectl apply -f examples/constructs/macvrf.yaml
kubectl -n agentic-netops-services get networks.fabric.agentic-netops.io -o wide
```

**Expected.** `Accepted=True` and `created` claims in `status.claimRefs`.

**If it fails.** Choose a free VNI in the band and a VLAN in `100–999`; delete and re-apply —
`docs/runbook.md` §17.

**Evidence.** `make test-provider-claims` (SC-045).

---

## 18. Structured logs and following a correlation id

**When.** Following a request across the tier and the provider.

**Before you start.** One JSON object per line (NFR-014): `ts` (UTC), `level`, `component`, `msg`,
`kind`/`namespace`/`name`, `correlation_id`, `thread_id` (tier). The correlation id is the label
`agentic-netops.io/correlation-id` on the tier's objects and **the trace id** of the request.

**Steps.**

```bash
CID=<correlation id>
kubectl -n agentic-netops-system logs deploy/srl-provider | jq -R -c --arg c "$CID" 'fromjson? | select(.correlation_id==$c)'
kubectl -n agentic-netops-agents logs deploy/deployer --all-containers | jq -R -c --arg c "$CID" 'fromjson? | select(.correlation_id==$c)'
```
In Grafana: `http://127.0.0.1:3000/d/intent-tier?var-correlation_id=<CID>` (after the port-forward of §14).

**Expected.** Every stage's lines carry the same id.

**If it fails.** Loop over all four agents and the provider — `docs/runbook.md` §18.

**Evidence.** The trace in the analytics store.

---

## 19. Host requirements

**When.** Sizing or checking a host.

**Before you start.** Linux x86-64 with **SSSE3**, kernel **≥ 4.10**, Docker with privileged
containers, no hypervisor needed. **Budget ≈2 vCPU / 2 GiB per SR Linux node** (four nodes), plus the
Kind cluster's budget, plus the tier's summed requests. **Measured per-node footprint** at idle after
convergence (T052, `tests/integration/footprint.sh`, from
`.evidence/agentic-netops_agentic-netops-fabric/20260921T115335Z/footprint.summary.stdout`): RSS mean
1342.3 / 1343.2 MiB on leaf01 / leaf02 and 1338.8 / 1340.6 MiB on spine01 / spine02; CPU mean ≈6.3–6.5 %
of one CPU per node. **Packet-rate ceiling**: 1000 PPS documented for the unlicensed container, ~5 kpps
measured in research (PC-S-10) — documented / measured in research, not re-observed; tests never assert
throughput. Both surfaces require an authenticated operator (FR-102), and a deletion blocks while a
target is unreachable (FR-103).

**Steps.**

```bash
grep -m1 -ow ssse3 /proc/cpuinfo; uname -r; nproc; free -m
scripts/lib/intent_tier.sh requests
```

**Expected.** The preflight reports available ≥ required.

**If it fails.** Free resources or run without the tier; never lower the thresholds.

**Evidence.** The T052 file above. Full detail: `docs/runbook.md` §19.
