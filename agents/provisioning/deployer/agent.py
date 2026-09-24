"""The deployer stage (T100): skill ``deploy-network-service``, four operations.

Every operation answers with a :class:`~common.schemas.stream.DeploymentReport` in the data part
(``reply_ok``). ``reply_failed`` — which the transport raises as a terminal ``WorkerFailedError`` —
is kept for an **out-of-contract request** only (no correlation id, an unknown operation, a
malformed assignment).

* ``create`` — ``{"operation":"create","assignment":NSI,"principal":str,"confirmation_2":{...}}``:
  refused with zero API calls unless ``confirmation_2.decided == "confirm"`` (FR-055, enforced
  here in the submission stage); then pre-flight → translate → stamp → dry-run → apply (finalizer
  set) → watch (:mod:`provisioning.deployer.submit`, :mod:`provisioning.deployer.watch`). A
  ``Network`` of this name already carrying this request's correlation id is a resumed request:
  nothing is re-submitted and the watch resumes.
* ``remove`` — ``{"operation":"remove","network":"migr-<sid>","principal":str,
  "confirmation_2":{...},"tier_removed"?:bool}``: re-read (out-of-band check), delete the
  ``Network`` (never a claim; never a second delete of one already deleting), watch until gone.
* ``status`` — ``{"operation":"status","network":"migr-<sid>","tier_removed":bool,
  "principal"?:str}``: read-only (:mod:`provisioning.deployer.status`).
* ``release_gate`` — ``{"operation":"release_gate","correlation_ids":[...]}``.

**A dependency failure is a report, not a worker failure** (NFR-010, AD-52): the cluster API —
the fail-closed admission webhook among it — or the translator sidecar not answering yields
``status: FAILED, retryable: true, dependency: <named>, submitted: false`` after the worker-call
retry rule, so the supervisor reports the dependency, keeps the thread resumable and — nothing
having been applied — the claims provisional (the release gate still names the id releasable).
"""

from __future__ import annotations

import asyncio
import logging
import re
import time
from collections.abc import Awaitable, Callable, Mapping
from datetime import UTC, datetime
from typing import Any

import httpx
from pydantic import ValidationError

from common.schemas.normalized_service_intent import NormalizedServiceIntent
from common.schemas.stream import DeploymentReport, ProgressEvent
from common.tracing import request_span
from common.transport import StageMessage, reply_failed, reply_ok
from config.settings import Settings
from provisioning.deployer.conditions import Live, network_ref
from provisioning.deployer.events import AuditEmitter
from provisioning.deployer.kube import ClusterUnavailableError, KubeClient, KubeError
from provisioning.deployer.stamp import CORRELATION_LABEL, StampError
from provisioning.deployer.status import read_status
from provisioning.deployer.submit import (
    DEFAULT_TRANSLATOR_URL,
    DependencyUnavailableError,
    SubmissionError,
    apply_all,
    dry_run_all,
    preflight,
    release_gate,
    rollback,
    stamp_all,
    translate,
    with_retry,
)
from provisioning.deployer.watch import watch_creation, watch_removal

log = logging.getLogger("agentic_netops.deployer")

OPERATIONS = ("create", "remove", "status", "release_gate")
DEFAULT_POLL_SECONDS = 2.0
_CID = re.compile(r"^[0-9a-f]{32}$")
_NETWORK = re.compile(r"^migr-[a-z0-9]([-a-z0-9]*[a-z0-9])?$")
_HOLDER = re.compile(r"already owned by Network ([^\s:]+)")


class OutOfContractError(ValueError):
    pass


def _confirmed(payload: Mapping[str, Any]) -> bool:
    c2 = payload.get("confirmation_2")
    return isinstance(c2, Mapping) and c2.get("decided") == "confirm"


def _str(payload: Mapping[str, Any], key: str) -> str:
    value = payload.get(key)
    if not isinstance(value, str) or not value.strip():
        raise OutOfContractError(f"out-of-contract request: {key} is required")
    return value.strip()


class Deployer:
    def __init__(self, settings: Settings, *,
                 kube_factory: Callable[[], KubeClient] | None = None,
                 translator_transport: httpx.AsyncBaseTransport | None = None,
                 translator_url: str | None = None,
                 clock: Callable[[], float] = time.monotonic,
                 sleep: Callable[[float], Awaitable[None]] = asyncio.sleep,
                 now: Callable[[], datetime] = lambda: datetime.now(UTC),
                 poll_seconds: float | None = None) -> None:
        extra = settings.extra or {}
        self.settings = settings
        self.kube_factory = kube_factory or KubeClient.in_cluster
        self._kube: KubeClient | None = None
        self.translator_transport = translator_transport
        self.translator_url = translator_url or extra.get("TRANSLATOR_URL") or \
            DEFAULT_TRANSLATOR_URL
        self.clock = clock
        self.sleep = sleep
        self.now = now
        self.poll = poll_seconds if poll_seconds is not None else float(
            extra.get("DEPLOYER_POLL_INTERVAL_SECONDS") or DEFAULT_POLL_SECONDS)
        self.timeout = settings.convergence_timeout_seconds
        self.retries = settings.worker_call_retries
        self.backoff = settings.worker_call_backoff_seconds

    @property
    def kube(self) -> KubeClient:
        if self._kube is None:
            self._kube = self.kube_factory()
        return self._kube

    # ----------------------------------------------------------------------------------------

    async def handle(self, request: StageMessage) -> Any:
        payload = request.data if isinstance(request.data, dict) else {}
        operation = payload.get("operation") or request.operation
        if operation not in OPERATIONS:
            return reply_failed(f"out-of-contract request: operation {operation!r} is not one "
                                f"of {', '.join(OPERATIONS)}")
        cid = request.correlation_id or ""
        if not _CID.match(cid):
            return reply_failed("out-of-contract request: no correlation id (32 lowercase hex)")
        thread_id = request.thread_id or ""
        if operation != "release_gate" and not thread_id:
            return reply_failed("out-of-contract request: no thread id")
        with request_span(f"deployer.{operation}", correlation_id=cid,
                          attributes={"thread_id": thread_id, "operation": operation}) as span:
            audit = AuditEmitter(lambda: self.kube, now=self.now, span=span.span)
            try:
                if operation == "create":
                    report = await self.create(payload, cid, thread_id, audit)
                elif operation == "remove":
                    report = await self.remove(payload, cid, thread_id, audit)
                elif operation == "status":
                    report = await self.status(payload, cid, thread_id, audit)
                else:
                    report = await self.gate(payload)
            except OutOfContractError as exc:
                return reply_failed(str(exc))
            except ClusterUnavailableError as exc:
                report = DeploymentReport(
                    operation=operation, status="FAILED", submitted=False, retryable=True,
                    dependency=exc.dependency,
                    message=f"{exc.dependency} unavailable: {exc.detail}; the request can be "
                            "resumed")
        text = report.message or f"{operation}: {report.status}"
        return reply_ok(text, report.model_dump(mode="json", exclude_none=True))

    # ----------------------------------------------------------------------------------------
    # create
    # ----------------------------------------------------------------------------------------

    async def create(self, payload: Mapping[str, Any], cid: str, thread_id: str,
                     audit: AuditEmitter) -> DeploymentReport:
        if not _confirmed(payload):
            # No submission without the second confirmation (FR-055) — before any API call.
            return DeploymentReport(
                operation="create", status="FAILED", submitted=False,
                message="refused: no submission without the second confirmation "
                        "(confirmation_2.decided must be confirm); nothing was submitted")
        principal = _str(payload, "principal")
        raw = payload.get("assignment")
        try:
            intent = NormalizedServiceIntent.parse(raw).to_wire()
        except (ValidationError, ValueError, TypeError) as exc:
            raise OutOfContractError(f"out-of-contract request: assignment: {exc}") from None
        network = f"migr-{intent['serviceId']}"

        existing = await self.kube.get_network(network)
        if existing is not None:
            labels = (existing.get("metadata") or {}).get("labels") or {}
            if labels.get(CORRELATION_LABEL) == cid:
                log.info("Network/%s already submitted by this request: resuming the watch",
                         network)
                return await self._watch(cid, [network], audit=audit, thread_id=thread_id,
                                         principal=principal)
            return DeploymentReport(
                operation="create", status="FAILED", submitted=False,
                causes=[f"Network/{network} already exists"],
                message=f"refused: Network/{network} already exists (another request "
                        "submitted it); a second service under that name is refused and nothing "
                        "was submitted")

        # 1. pre-flight (the intent namespace only)
        conflicts = preflight(intent, network, await self.kube.list_networks())
        if conflicts:
            return DeploymentReport(
                operation="create", status="FAILED", submitted=False, causes=conflicts,
                message="refused by the pre-flight: " + "; ".join(conflicts)
                        + "; nothing was submitted")
        # 2. translate
        try:
            async with httpx.AsyncClient(transport=self.translator_transport,
                                         timeout=30.0) as client:
                manifests = await translate(client, self.translator_url, intent)
            # 3. stamp
            stamped = stamp_all(manifests, correlation_id=cid, thread_id=thread_id,
                                principal=principal, submitted_at=self.now())
            # 4. dry-run every object
            dry_runs = await dry_run_all(self.kube, stamped, retries=self.retries,
                                         backoff=self.backoff, sleep=self.sleep)
        except DependencyUnavailableError as exc:
            return DeploymentReport(operation="create", status="FAILED", submitted=False,
                                    retryable=True, dependency=exc.dependency,
                                    message=exc.message)
        except (SubmissionError, StampError) as exc:
            message = getattr(exc, "message", str(exc))
            causes = list(getattr(exc, "causes", []) or [])
            holders = _HOLDER.findall(message)
            if holders:
                causes.extend(f"holder: Network {h}" for h in holders)
            return DeploymentReport(
                operation="create", status="FAILED", submitted=False,
                causes=causes or [message], message=f"refused: {message}")

        # 5. apply — the finalizer is already in every stamped object
        order = [str(m["metadata"]["name"]) for m in stamped]
        try:
            submitted = await apply_all(self.kube, dry_runs, order, retries=self.retries,
                                        backoff=self.backoff, sleep=self.sleep)
        except DependencyUnavailableError as exc:
            return DeploymentReport(operation="create", status="FAILED", submitted=False,
                                    retryable=True, dependency=exc.dependency,
                                    message=exc.message)
        except SubmissionError as exc:
            # 6. roll back by the correlation label
            result = await rollback(self.kube, cid)
            status_word = "rolled back" if result.ok else "ROLLBACK FAILED"
            return DeploymentReport(
                operation="create", status="FAILED", submitted=bool(result.rolled_back or
                                                                    result.survivors),
                rolled_back=result.rolled_back, survivors=result.survivors or None,
                message=f"{exc.message}; {status_word}: {result.sentence()}")

        resources = [network_ref(n, uid=(submitted.applied[n].get("metadata") or {}).get("uid"))
                     for n in order]
        for name in order:
            await audit.emit("submit", correlation_id=cid, thread_id=thread_id,
                             principal=principal,
                             resources=[r for r in resources if r.name == name],
                             reason=None, submitted_spec_sha256=submitted.hashes[name],
                             message=f"Network/{name} submitted by {principal} "
                                     f"(submitted-spec sha256 {submitted.hashes[name]})")
        return await self._watch(cid, order, audit=audit, thread_id=thread_id,
                                 principal=principal)

    async def _watch(self, cid: str, names: list[str], *, audit: AuditEmitter,
                     thread_id: str, principal: str) -> DeploymentReport:
        result = await watch_creation(self.kube, names, bound=self.timeout, poll=self.poll,
                                      clock=self.clock, sleep=self.sleep)
        if result.outcome == "converged":
            return DeploymentReport(operation="create", status="COMPLETED",
                                    resources=result.resources, progress=result.progress,
                                    message=result.message)
        if result.outcome == "deleted":
            await audit.emit("out_of_band", correlation_id=cid, thread_id=thread_id,
                             principal=principal, resources=result.resources,
                             reason="deleted", message=result.message)
            return DeploymentReport(operation="create", status="FAILED",
                                    resources=result.resources, progress=result.progress,
                                    out_of_band="deleted", message=result.message)
        return DeploymentReport(operation="create", status="FAILED", resources=result.resources,
                                progress=result.progress, message=result.message)

    # ----------------------------------------------------------------------------------------
    # remove
    # ----------------------------------------------------------------------------------------

    async def remove(self, payload: Mapping[str, Any], cid: str, thread_id: str,
                     audit: AuditEmitter) -> DeploymentReport:
        network = _network(payload)
        if not _confirmed(payload):
            return DeploymentReport(
                operation="remove", status="FAILED", submitted=False,
                message=f"refused: Network/{network} is not removed without the second "
                        "confirmation (confirmation_2.decided must be confirm); nothing was "
                        "deleted")
        principal = _str(payload, "principal")
        # Re-read the live object (FR-105).
        answer = await read_status(self.kube, network,
                                   tier_removed=bool(payload.get("tier_removed")))
        if answer.out_of_band:
            await audit.emit("out_of_band", correlation_id=cid, thread_id=thread_id,
                             principal=principal, resources=[answer.resource],
                             reason=answer.out_of_band, message=answer.message,
                             **_hashes(answer.live))
        if answer.live is None:
            return DeploymentReport(
                operation="remove", status="COMPLETED" if not answer.out_of_band else "FAILED",
                submitted=False, resources=[answer.resource], out_of_band=answer.out_of_band,
                state="absent", message=answer.message + "; nothing was deleted")
        live: Live = answer.live
        if not live.meta.get("deletionTimestamp"):
            await with_retry(lambda: self.kube.delete_network(network), retries=self.retries,
                             backoff=self.backoff, sleep=self.sleep,
                             what=f"delete of Network/{network}")
            # The one remove event, emitted when the delete is issued (AD-63).
            await audit.emit("remove", correlation_id=cid, thread_id=thread_id,
                             principal=principal, resources=[live.ref()], reason=None,
                             submitted_spec_sha256=live.submitted_hash,
                             message=f"removal of Network/{network} requested by {principal}")
        result = await watch_removal(self.kube, network, bound=self.timeout, poll=self.poll,
                                     clock=self.clock, sleep=self.sleep)
        prefix = (answer.message.split(". Live state:")[0] + ". ") if \
            answer.out_of_band == "modified" else ""
        if result.outcome == "gone":
            return DeploymentReport(operation="remove", status="COMPLETED",
                                    resources=result.resources, progress=result.progress,
                                    out_of_band=answer.out_of_band, state="absent",
                                    message=prefix + result.message)
        return DeploymentReport(operation="remove", status="PROVISIONING",
                                resources=result.resources, progress=result.progress,
                                out_of_band=answer.out_of_band, state="removing",
                                live=result.live.summary() if result.live else None,
                                message=prefix + result.message)

    # ----------------------------------------------------------------------------------------
    # status, release gate
    # ----------------------------------------------------------------------------------------

    async def status(self, payload: Mapping[str, Any], cid: str, thread_id: str,
                     audit: AuditEmitter) -> DeploymentReport:
        network = _network(payload)
        tier_removed = payload.get("tier_removed", False)
        if not isinstance(tier_removed, bool):
            raise OutOfContractError("out-of-contract request: tier_removed must be a boolean")
        principal = payload.get("principal") if isinstance(payload.get("principal"), str) and \
            payload.get("principal") else "unknown"
        answer = await read_status(self.kube, network, tier_removed=tier_removed)
        if answer.out_of_band:
            await audit.emit("out_of_band", correlation_id=cid, thread_id=thread_id,
                             principal=str(principal), resources=[answer.resource],
                             reason=answer.out_of_band, message=answer.message,
                             **_hashes(answer.live))
        progress = []
        if answer.live is not None and answer.live.ready is not None:
            progress.append(ProgressEvent(
                status="VERIFIED" if answer.state == "converged" else "PROVISIONING",
                resource=f"Network/{network}", ready=answer.live.ready,
                reason=answer.live.reason))
        return DeploymentReport(
            operation="status", status="COMPLETED", submitted=answer.live is not None,
            resources=[answer.resource], progress=progress, state=answer.state,  # type: ignore[arg-type]
            out_of_band=answer.out_of_band,  # type: ignore[arg-type]
            live=answer.live.summary() if answer.live else None, message=answer.message)

    async def gate(self, payload: Mapping[str, Any]) -> DeploymentReport:
        ids = payload.get("correlation_ids")
        if not isinstance(ids, list) or not all(isinstance(i, str) and _CID.match(i)
                                                for i in ids):
            raise OutOfContractError("out-of-contract request: correlation_ids must be a list "
                                     "of 32-hex correlation ids")
        releasable, refused = await release_gate(self.kube, ids)
        message = (f"releasable: {', '.join(releasable) or 'none'}" +
                   ("; refused — the Network exists: " + ", ".join(
                       f"{r['correlation_id']} ({r['network']})" for r in refused)
                    if refused else ""))
        return DeploymentReport.parse({
            "operation": "release_gate", "status": "COMPLETED", "submitted": False,
            "releasable": releasable, "refused": refused, "message": message})


def _hashes(live: Live | None) -> dict[str, str | None]:
    """Both spec hashes an out-of-band event carries while the object exists (data-model.md §16)."""
    if live is None:
        return {}
    return {"submitted_spec_sha256": live.submitted_hash, "live_spec_sha256": live.live_hash}


def _network(payload: Mapping[str, Any]) -> str:
    network = _str(payload, "network")
    if network.startswith("Network/"):
        network = network.split("/", 1)[1]
    if not _NETWORK.match(network) or len(network) > 63:
        raise OutOfContractError(f"out-of-contract request: network {network!r} is not a "
                                 "migr-<serviceId> name")
    return network


def make_handler(settings: Settings, **kwargs: Any) -> Callable[[StageMessage], Awaitable[Any]]:
    deployer = Deployer(settings, **kwargs)

    async def handler(request: StageMessage) -> Any:
        try:
            return await deployer.handle(request)
        except KubeError as exc:  # a refusal the stage did not expect: named, terminal
            return reply_failed(f"cluster API refused the request: {exc}")

    handler.deployer = deployer  # type: ignore[attr-defined]
    return handler


__all__ = ["OPERATIONS", "Deployer", "make_handler"]
