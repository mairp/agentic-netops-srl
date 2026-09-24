"""The convergence and removal watches (T100; contracts/kubernetes-objects.md §"Submission
contract" step 7 and §Removal, data-model.md §15 §17, FR-067, FR-069, AD-40, AD-53, AD-62, AD-63).

A **creation** watch polls each submitted ``Network`` until one of three outcomes — every object
``Ready=True`` (converged), a terminal refusal, or the convergence timeout
(``DEPLOYER_CONVERGENCE_TIMEOUT_SECONDS``, 150 s) — and reports which. ``Ready=Unknown`` is none of
them: the watch stays open on it. ``Ready=False/Deleting`` (or the object gone) under a creation
watch is the object deleted under it: a terminal failure naming the deletion.

A **removal** watch polls until the object no longer exists, under the same bound: gone is
``COMPLETED``; still present is the removal *in progress*, naming what its ``Deleting`` condition
says is outstanding. It never retries the delete.

Every progress event carries ``ready`` as the ``Ready`` condition's status string, unaltered, and
its ``reason`` beside it; an event is recorded whenever the pair changes. Nothing is emitted before
a ``Ready`` condition has been read — a ``None`` is never put on a chunk.
"""

from __future__ import annotations

from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field
from typing import Literal

from common.schemas.audit import ResourceRef
from common.schemas.stream import ProgressEvent
from provisioning.deployer.conditions import REASON_DELETING, Live, network_ref
from provisioning.deployer.kube import KubeClient

Clock = Callable[[], float]
Sleep = Callable[[float], Awaitable[None]]


@dataclass
class WatchResult:
    outcome: Literal["converged", "terminal", "timeout", "deleted", "gone", "in_progress"]
    progress: list[ProgressEvent] = field(default_factory=list)
    resources: list[ResourceRef] = field(default_factory=list)
    message: str = ""
    live: Live | None = None


def _event(status: str, name: str, live: Live) -> ProgressEvent:
    return ProgressEvent(status=status, resource=f"Network/{name}",  # type: ignore[arg-type]
                         ready=live.ready, reason=live.reason)


async def watch_creation(kube: KubeClient, names: list[str], *, bound: float, poll: float,
                         clock: Clock, sleep: Sleep) -> WatchResult:
    deadline = clock() + bound
    seen: dict[str, tuple[str | None, str | None]] = {}
    result = WatchResult("timeout")
    lives: dict[str, Live] = {}
    while True:
        for name in names:
            obj = await kube.get_network(name)
            if obj is None:
                result.outcome = "deleted"
                result.message = (f"Network/{name} was deleted while the tier watched it "
                                  "converge: it no longer exists, and no removal by the intent "
                                  "tier is recorded for it — deleted outside the intent tier")
                result.resources = [lives[n].ref() if n in lives else network_ref(n)
                                    for n in names]
                return result
            live = lives[name] = Live(name, obj)
            pair = (live.ready, live.reason)
            if live.ready is not None and seen.get(name) != pair:
                seen[name] = pair
                status = "VERIFIED" if live.ready == "True" else "PROVISIONING"
                result.progress.append(_event(status, name, live))
            if live.deleting:
                result.outcome = "deleted"
                result.message = (
                    f"Network/{name} is being deleted (Ready=False/{REASON_DELETING}) while the "
                    "tier watched it converge; no removal by the intent tier is recorded for "
                    f"it — deleted outside the intent tier. {live.outstanding()}")
                result.live = live
                result.resources = [lv.ref() for lv in lives.values()]
                return result
            terminal = live.terminal()
            if terminal:
                result.outcome = "terminal"
                result.message = (f"Network/{name} was refused by the provider — a terminal "
                                  f"failure: {terminal}")
                result.live = live
                result.resources = [lv.ref() for lv in lives.values()]
                return result
        result.resources = [lives[n].ref() for n in names]
        if all(lives[n].ready == "True" for n in names):
            result.outcome = "converged"
            result.message = ", ".join(f"Network/{n}" for n in names) + " converged (Ready=True)"
            return result
        now = clock()
        if now >= deadline:
            waiting = []
            for n in names:
                lv = lives[n]
                if lv.ready == "True":
                    continue
                if lv.ready == "Unknown":
                    waiting.append(f"Network/{n}: readiness is unknown — Ready=Unknown/"
                                   f"{lv.reason}: {lv.ready_message}")
                elif lv.ready is None:
                    waiting.append(f"Network/{n}: no Ready condition reported yet")
                else:
                    waiting.append(f"Network/{n}: Ready={lv.ready}/{lv.reason}: "
                                   f"{lv.ready_message}")
            result.outcome = "timeout"
            result.message = (f"convergence timeout: not Ready within {bound:g} s — "
                              + "; ".join(waiting))
            return result
        await sleep(min(poll, max(deadline - now, 0.0)))


async def watch_removal(kube: KubeClient, name: str, *, bound: float, poll: float,
                        clock: Clock, sleep: Sleep) -> WatchResult:
    deadline = clock() + bound
    seen: tuple[str | None, str | None] | None = None
    result = WatchResult("in_progress")
    while True:
        obj = await kube.get_network(name)
        if obj is None:
            result.outcome = "gone"
            result.message = (f"Network/{name} removed: the object no longer exists; the "
                              "provider's finalizer released its identifiers")
            result.resources = [network_ref(name)]
            return result
        live = result.live = Live(name, obj)
        pair = (live.ready, live.reason)
        if live.ready == "False" and live.reason == REASON_DELETING and pair != seen:
            seen = pair
            result.progress.append(_event("PROVISIONING", name, live))
        result.resources = [live.ref()]
        now = clock()
        if now >= deadline:
            result.outcome = "in_progress"
            result.message = (
                f"removal in progress: Network/{name} still exists after {bound:g} s — "
                f"{live.outstanding()}. It completes without operator action when that ends; "
                "the delete was accepted and is not repeated, and a status request reports it "
                "from the live object")
            return result
        await sleep(min(poll, max(deadline - now, 0.0)))


__all__ = ["WatchResult", "watch_creation", "watch_removal"]
