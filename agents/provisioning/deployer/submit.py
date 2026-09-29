"""The submission transaction and the release gate (T100; contracts/kubernetes-objects.md
§"Submission contract", contracts/translator-api.md, FR-064…FR-068, FR-101, FR-103, FR-109,
AD-32, AD-33, AD-52).

The Kubernetes API has no multi-object transaction; this is the contract's substitute, in its
fixed order:

1. **Pre-flight** (:mod:`provisioning.deployer.preflight`) — the intent namespace only: a second
   owner of a (node, port, VLAN) subinterface, a conflicting tagging mode on a (node, port), a
   second access list on a (node, port, subinterface, direction, address family) binding, or a
   mode other than the site inventory declares, refused naming the incumbent (a deleting
   incumbent still holds, and the refusal says so). A holder in ``agentic-netops-services`` is
   invisible here and is refused by the cross-object admission rules at step 4.
2. **Translate** — ``POST {TRANSLATOR_URL}/v1/translate`` on the loopback sidecar; a ``422`` is a
   refusal carrying the translator's complete causes.
3. **Stamp** — :mod:`provisioning.deployer.stamp`.
4. **Dry run** every object; any rejection aborts the whole bundle naming the object. A dry-run
   the API server fails because the fail-closed admission webhook is unreachable is **not** a
   rejection: it is the cluster API dependency unavailable (NFR-010), retried under the
   worker-call retry rule (data-model.md §25) and then reported as that — nothing applied,
   nothing rolled back, the claims still provisional.
5. **Apply** in a deterministic order, the provider's finalizer already set; the applied body is
   the dry-run object plus exactly the submitted-spec hash annotation.
6. **Roll back** on failure by the correlation label, reporting the rolled-back set; a failed
   rollback is reported failed naming the survivors (R-21). The rollback deletes ``Network``s
   and never a claim.

The **release gate** is the deployer's alone (it is the one tier identity that may read a
``Network``): a correlation id is releasable exactly when no ``Network`` in the intent namespace
carries it.
"""

from __future__ import annotations

import logging
from collections.abc import Awaitable, Callable, Mapping
from dataclasses import dataclass, field
from datetime import datetime
from typing import Any

import httpx

from common import tracing
from provisioning.deployer.kube import (
    ClusterUnavailableError,
    KubeAPIError,
    KubeClient,
    KubeError,
)
from provisioning.deployer.preflight import preflight
from provisioning.deployer.stamp import CORRELATION_LABEL, apply_body, stamp

log = logging.getLogger("agentic_netops.deployer.submit")

DEFAULT_TRANSLATOR_URL = "http://127.0.0.1:8090"
TRANSLATE_PATH = "/v1/translate"
# The sidecar logs the request under this correlation id (NFR-014; cmd/intent-translator).
CORRELATION_HEADER = "X-Correlation-Id"
# The VLAN bands (AD-33): a VLAN the operator names is drawn from the naming band and is never
# claimed; one the authority allocates comes only from the allocation band. They are disjoint, so
# the pre-flight never has an allocated-versus-named VLAN collision to look for.
NAMING_VLAN_BAND = range(100, 1000)
ALLOCATION_VLAN_BAND = range(1000, 4001)

class SubmissionError(Exception):
    """A step of the transaction failed; ``phase`` names it. ``manifest`` is the object the
    cluster rejected, when one was — the payload that failed validation, for the trace (T135)."""

    def __init__(self, phase: str, message: str, *, causes: list[str] | None = None,
                 manifest: Mapping[str, Any] | None = None) -> None:
        super().__init__(message)
        self.phase = phase
        self.message = message
        self.causes = list(causes or [])
        self.manifest = dict(manifest) if manifest is not None else None


class DependencyUnavailableError(SubmissionError):
    """A dependency did not answer (NFR-010): retryable, the thread resumable."""

    def __init__(self, dependency: str, message: str) -> None:
        super().__init__("dependency", message)
        self.dependency = dependency


# --------------------------------------------------------------------------------------------------
# retry (data-model.md §25: 2 retries after the first attempt, backoff from 1 s: 1 s, then 2 s)
# --------------------------------------------------------------------------------------------------


async def with_retry[T](call: Callable[[], Awaitable[T]], *, retries: int, backoff: float,
                     sleep: Callable[[float], Awaitable[None]], what: str) -> T:
    """Retry ``call`` on :class:`ClusterUnavailableError` only; a refusal is never retried."""
    for attempt in range(retries + 1):
        try:
            return await call()
        except ClusterUnavailableError as exc:
            if attempt >= retries:
                raise
            log.warning("%s: %s (attempt %d of %d); retrying", what, exc, attempt + 1,
                        retries + 1)
            await sleep(backoff * (2 ** attempt))
    raise AssertionError("unreachable")  # pragma: no cover


# --------------------------------------------------------------------------------------------------
# 1. pre-flight
# --------------------------------------------------------------------------------------------------


# :func:`preflight` lives in :mod:`provisioning.deployer.preflight` (T112) and is re-exported here.


# --------------------------------------------------------------------------------------------------
# 2. translate
# --------------------------------------------------------------------------------------------------


async def translate(client: httpx.AsyncClient, base_url: str,
                    intent: Mapping[str, Any]) -> list[dict[str, Any]]:
    url = base_url.rstrip("/") + TRANSLATE_PATH
    try:
        cid = tracing.current_correlation_id()
        response = await client.post(url, json=dict(intent),
                                     headers={CORRELATION_HEADER: cid} if cid else None)
    except httpx.TransportError as exc:
        raise DependencyUnavailableError(
            "translator sidecar", f"translator sidecar unavailable at {url}: "
                                  f"{type(exc).__name__}: {exc}") from None
    if response.status_code == 422:
        try:
            body = response.json()
        except ValueError:
            body = {}
        causes = [str(c) for c in (body.get("causes") or [])] if isinstance(body, dict) else []
        raise SubmissionError("translate", "the translator refused the assignment: "
                              + ("; ".join(causes) or response.text.strip()), causes=causes)
    if response.status_code // 100 != 2:
        raise DependencyUnavailableError(
            "translator sidecar",
            f"translator sidecar at {url} answered HTTP {response.status_code}: "
            f"{response.text.strip()[:500]}")
    try:
        body = response.json()
    except ValueError:
        raise SubmissionError("translate", "the translator's answer is not JSON") from None
    manifests = body.get("manifests") if isinstance(body, dict) else None
    if not isinstance(manifests, list) or not manifests or not all(
            isinstance(m, dict) for m in manifests):
        raise SubmissionError("translate", "the translator returned no manifests")
    return manifests


# --------------------------------------------------------------------------------------------------
# 4 to 6: dry run, apply, roll back
# --------------------------------------------------------------------------------------------------


@dataclass
class Submitted:
    names: list[str]
    dry_run: dict[str, dict[str, Any]] = field(default_factory=dict)
    applied: dict[str, dict[str, Any]] = field(default_factory=dict)
    hashes: dict[str, str] = field(default_factory=dict)


@dataclass
class Rollback:
    rolled_back: list[str]
    survivors: list[str]

    @property
    def ok(self) -> bool:
        return not self.survivors

    def sentence(self) -> str:
        if not self.rolled_back and not self.survivors:
            return "nothing was applied, so nothing was rolled back"
        parts = []
        if self.rolled_back:
            parts.append("rolled back (deleted by the correlation label; the provider's "
                         "finalizer releases what it adopted, and no claim is released while "
                         "the object exists): " + ", ".join(self.rolled_back))
        if self.survivors:
            parts.append("ROLLBACK FAILED — still present: " + ", ".join(self.survivors))
        return "; ".join(parts)


def _name(manifest: Mapping[str, Any]) -> str:
    return str((manifest.get("metadata") or {}).get("name"))


async def dry_run_all(kube: KubeClient, stamped: list[dict[str, Any]], *, retries: int,
                      backoff: float, sleep: Callable[[float], Awaitable[None]]
                      ) -> dict[str, dict[str, Any]]:
    """Step 4. Raises :class:`SubmissionError` naming the rejected object (the bundle aborts) or
    :class:`DependencyUnavailableError` once the retry rule is spent."""
    results: dict[str, dict[str, Any]] = {}
    for manifest in stamped:
        name = _name(manifest)
        try:
            results[name] = await with_retry(
                lambda m=manifest: kube.apply_network(m, dry_run=True), retries=retries,
                backoff=backoff, sleep=sleep, what=f"dry-run of Network/{name}")
        except ClusterUnavailableError as exc:
            raise DependencyUnavailableError(
                exc.dependency,
                f"cluster API dependency unavailable: the server-side dry-run of Network/{name} "
                f"could not be evaluated after {retries + 1} attempts — {exc}. This is not a "
                "refusal of the request: nothing was applied, so nothing was rolled back; the "
                "request's claims are still provisional and the thread can be resumed") from None
        except KubeAPIError as exc:
            raise SubmissionError(
                "dry-run", f"the server-side dry-run rejected Network/{name}: {exc.message} — "
                           "the whole bundle is aborted and nothing was applied",
                manifest=manifest) from None
    return results


async def apply_all(kube: KubeClient, dry_runs: dict[str, dict[str, Any]],
                    order: list[str], *, retries: int, backoff: float,
                    sleep: Callable[[float], Awaitable[None]]) -> Submitted:
    """Step 5, in ``order``. A rejection — or the cluster API lost once something is applied —
    raises :class:`SubmissionError` after nothing further is applied; the caller rolls back. The
    cluster API unavailable (after the retry rule) before the first object is applied is the
    dependency failure of step 4: nothing applied, nothing to roll back."""
    submitted = Submitted(names=list(order), dry_run=dry_runs)
    for name in order:
        body, digest = apply_body(dry_runs[name])
        submitted.hashes[name] = digest
        try:
            submitted.applied[name] = await with_retry(
                lambda b=body: kube.apply_network(b, dry_run=False), retries=retries,
                backoff=backoff, sleep=sleep, what=f"apply of Network/{name}")
        except KubeAPIError as exc:
            raise SubmissionError("apply", f"the apply of Network/{name} was rejected: "
                                           f"{exc.message}", manifest=body) from None
        except ClusterUnavailableError as exc:
            if not submitted.applied:
                raise DependencyUnavailableError(
                    exc.dependency,
                    f"cluster API dependency unavailable: the apply of Network/{name} could not "
                    f"be made after {retries + 1} attempts — {exc}. Nothing was applied, so "
                    "nothing was rolled back; the request's claims are still provisional and "
                    "the thread can be resumed") from None
            raise SubmissionError("apply", f"the apply of Network/{name} failed: {exc}") from None
    return submitted


async def rollback(kube: KubeClient, correlation_id: str) -> Rollback:
    """Step 6: delete every ``Network`` carrying the correlation label — never a claim."""
    selector = f"{CORRELATION_LABEL}={correlation_id}"
    try:
        found = await kube.list_networks(selector)
    except KubeError as exc:
        return Rollback([], [f"every Network labelled {selector} (the list failed: {exc})"])
    rolled, survivors = [], []
    for obj in sorted(found, key=_name):
        name = _name(obj)
        try:
            await kube.delete_network(name)
            rolled.append(f"Network/{name}")
        except KubeError as exc:
            survivors.append(f"Network/{name} ({exc})")
    return Rollback(rolled, survivors)


async def release_gate(kube: KubeClient, correlation_ids: list[str]
                       ) -> tuple[list[str], list[dict[str, str]]]:
    """``(releasable, refused)``: an id is releasable exactly when no ``Network`` carries it —
    a ``Network`` being deleted still exists and still refuses its id (FR-109, AD-32)."""
    releasable: list[str] = []
    refused: list[dict[str, str]] = []
    for cid in correlation_ids:
        found = await kube.list_networks(f"{CORRELATION_LABEL}={cid}")
        if found:
            refused.extend({"correlation_id": cid, "network": f"Network/{_name(o)}"}
                           for o in sorted(found, key=_name))
        else:
            releasable.append(cid)
    return releasable, refused


def stamp_all(manifests: list[dict[str, Any]], *, correlation_id: str, thread_id: str,
              principal: str, submitted_at: datetime) -> list[dict[str, Any]]:
    stamped = [stamp(m, correlation_id=correlation_id, thread_id=thread_id, principal=principal,
                     submitted_at=submitted_at) for m in manifests]
    names = [_name(m) for m in stamped]
    if len(set(names)) != len(names):
        raise SubmissionError("stamp", "the translator emitted two Networks with one name")
    # The deterministic apply order: by name.
    return sorted(stamped, key=_name)


__all__ = [
    "ALLOCATION_VLAN_BAND",
    "DEFAULT_TRANSLATOR_URL",
    "NAMING_VLAN_BAND",
    "DependencyUnavailableError",
    "Rollback",
    "SubmissionError",
    "Submitted",
    "apply_all",
    "dry_run_all",
    "preflight",
    "release_gate",
    "rollback",
    "stamp_all",
    "translate",
    "with_retry",
]
