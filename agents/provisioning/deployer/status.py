"""The status answer and the out-of-band check (T100; data-model.md §15 §17, FR-057, FR-069,
FR-105, CD-04, AD-40, AD-53, AD-58).

Every status and removal request re-reads the live object; the answer is built from it and never
from a remembered status:

* present, hash matches — the live state: converged, progressing, readiness *unknown* (naming the
  target from the condition — never "converged", never "failed"), *being removed* (repeating what
  the ``Deleting`` condition names as outstanding — never "failed"), or a terminal refusal;
* present, hash differs — **modified outside the intent tier**, then the live state;
* absent and no tier removal recorded — **deleted outside the intent tier**.

The last two emit an ``out_of_band`` audit event and increment the counter. A status request
writes **nothing** to the ``Network`` (the audit event's Kubernetes Event mirror is not a write to
the object).
"""

from __future__ import annotations

from dataclasses import dataclass

from common.schemas.audit import ResourceRef
from provisioning.deployer.conditions import Live, network_ref
from provisioning.deployer.kube import KubeClient


@dataclass
class StatusAnswer:
    state: str
    message: str
    out_of_band: str | None
    live: Live | None
    resource: ResourceRef


def describe(live: Live) -> tuple[str, str]:
    """``(state, sentence)`` of a present object — no out-of-band prefix."""
    ref = f"Network/{live.name}"
    if live.deleting:
        return "removing", (f"{ref} is being removed (Ready=False/Deleting): "
                            f"{live.outstanding()}")
    terminal = live.terminal()
    if terminal:
        return "failed", f"{ref} was refused by the provider: {terminal}"
    if live.ready == "True":
        return "converged", f"{ref} is converged (Ready=True)"
    if live.ready == "Unknown":
        return "unknown", (f"{ref}: its readiness is unknown — Ready=Unknown/{live.reason}: "
                           f"{live.ready_message or 'the read-back could not run'}")
    if live.ready is None:
        return "progressing", f"{ref} is accepted; the provider has not reported Ready yet"
    return "progressing", (f"{ref} is not Ready yet — Ready=False/{live.reason}: "
                           f"{live.ready_message}")


async def read_status(kube: KubeClient, name: str, *, tier_removed: bool) -> StatusAnswer:
    obj = await kube.get_network(name)
    if obj is None:
        if tier_removed:
            return StatusAnswer("absent", f"Network/{name} no longer exists: the intent tier "
                                          "removed it", None, None, network_ref(name))
        return StatusAnswer(
            "absent", f"Network/{name} was deleted outside the intent tier: it no longer "
                      "exists and no removal by the tier is recorded for it; the tier does "
                      "not re-create it", "deleted", None, network_ref(name))
    live = Live(name, obj)
    state, sentence = describe(live)
    if live.modified:
        submitted = live.submitted_hash or "(no submitted-spec hash annotation)"
        sentence = (f"Network/{name} was modified outside the intent tier: its spec hashes to "
                    f"{live.live_hash}, not the submitted {submitted}. Live state: {sentence}")
        return StatusAnswer(state, sentence, "modified", live, live.ref())
    return StatusAnswer(state, sentence, None, live, live.ref())


__all__ = ["StatusAnswer", "describe", "read_status"]
