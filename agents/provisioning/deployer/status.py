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

The construct is derived **when the object is read** (T121; FR-026, FR-027, quickstart.md §14;
the Go twin is ``pkg/fabricapi/construct.go``): a service that converged before the vocabulary
changed may carry a retired service type in ``agentic-netops.io/service-type`` (``L2VNI``,
``VPLS``, ``L2L3-IRB``, …). It is reported by the construct that name resolves to
(contracts/construct-vocabulary.md §2, through the mapper catalogue's :meth:`Catalogue.fold`), the
stored vocabulary is presented as provenance — never as a type — and the stored record is never
rewritten. No stored type: the construct is read from the spec's shape. A stored type naming no
construct is reported as unknown, never guessed.
"""

from __future__ import annotations

import functools
import json
from collections.abc import Mapping
from dataclasses import dataclass
from typing import Any

from common.schemas.audit import ResourceRef
from provisioning.deployer.conditions import Live, network_ref
from provisioning.deployer.kube import KubeClient
from provisioning.mapper import catalogue as vocabulary

SERVICE_TYPE_ANNOTATION = "agentic-netops.io/service-type"
SOURCE_SERVICE_TYPE_ANNOTATION = "agentic-netops.io/source-service-type"
LIMITED_EQUIVALENCE_ANNOTATION = "agentic-netops.io/limited-equivalence"


@functools.cache
def _catalogue() -> vocabulary.Catalogue:
    return vocabulary.load()  # the packaged vocabulary: the deployer mounts no catalogue


def _key(name: str) -> str:
    return "".join(ch for ch in name.strip().lower() if ch not in "-_ .+")


@dataclass(frozen=True)
class ConstructView:
    """What a live ``Network`` is reported as — derived at read time, never stored."""

    construct: str | None
    stored_type: str | None = None
    source_service_type: str | None = None
    provenance: str | None = None
    limited_equivalence: str | None = None
    retired: bool = False
    derived: bool = False
    unknown: bool = False

    def label(self) -> str:
        """The parenthetical an operator reads after ``Network/<name>``."""
        if self.unknown:
            return (f"construct unknown: its stored record names none of "
                    f"{', '.join(vocabulary.CONSTRUCTS)} — {self.stored_type!r} is reported as "
                    "stored, not guessed")
        if self.construct is None:
            return "construct not recorded"
        parts = [self.construct]
        if self.provenance:
            parts.append(f"created as {self.provenance} — provenance, not a type")
        if self.limited_equivalence:
            parts.append(f"limited equivalence: {self.limited_equivalence}")
        return "; ".join(parts)


def derive_construct(obj: Mapping[str, Any] | None) -> ConstructView:
    """The construct of a live object from its stored annotations (or its spec's shape). A pure
    read: ``obj`` is never modified."""
    obj = obj if isinstance(obj, Mapping) else {}
    meta = obj.get("metadata") if isinstance(obj.get("metadata"), Mapping) else {}
    raw = meta.get("annotations") if isinstance(meta.get("annotations"), Mapping) else {}

    def ann(key: str) -> str | None:
        value = raw.get(key)
        return value if isinstance(value, str) and value.strip() else None

    stored, source = ann(SERVICE_TYPE_ANNOTATION), ann(SOURCE_SERVICE_TYPE_ANNOTATION)
    limited = ann(LIMITED_EQUIVALENCE_ANNOTATION)
    if stored is None:
        construct = _shape_construct(obj.get("spec"))
        return ConstructView(construct, None, source, source, limited,
                             derived=construct is not None)
    folded = _catalogue().fold(stored)
    if folded is None or folded[0] not in vocabulary.CONSTRUCTS:
        return ConstructView(None, stored, source, None, limited, unknown=True)
    construct, alias_source = folded
    retired = _key(stored) != _key(construct)
    provenance = source or alias_source or (stored if retired else None)
    return ConstructView(construct, stored, source, provenance, limited, retired=retired)


def _shape_construct(spec: Any) -> str | None:
    if not isinstance(spec, Mapping):
        return None
    for field, construct in (("vlans", "vlan"), ("bridgeDomains", "mac-vrf"),
                             ("routers", "ip-vrf"), ("accessLists", "acl")):
        items = spec.get(field)
        if isinstance(items, list) and any(isinstance(i, Mapping) for i in items):
            return construct
    return None


@dataclass
class StatusAnswer:
    state: str
    message: str
    out_of_band: str | None
    live: Live | None
    resource: ResourceRef
    construct: str | None = None
    provenance: str | None = None


def describe(live: Live) -> tuple[str, str]:
    """``(state, sentence)`` of a present object — no out-of-band prefix. The object is named with
    its construct, derived from the stored record as it is read now."""
    ref = f"Network/{live.name} ({derive_construct(live.obj).label()})"
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
    view = derive_construct(obj)
    state, sentence = describe(live)
    if live.modified:
        submitted = live.submitted_hash or "(no submitted-spec hash annotation)"
        sentence = (f"Network/{name} was modified outside the intent tier: its spec hashes to "
                    f"{live.live_hash}, not the submitted {submitted}. Live state: {sentence}")
        spec = live.obj.get("spec") if isinstance(live.obj, Mapping) else None
        described = spec.get("description") if isinstance(spec, Mapping) else None
        if isinstance(described, str) and described:
            # the live record as it reads now, never the remembered one (FR-105; quickstart §26)
            sentence += f"; its live description reads {json.dumps(described)}"
        return StatusAnswer(state, sentence, "modified", live, live.ref(), view.construct,
                            view.provenance)
    return StatusAnswer(state, sentence, None, live, live.ref(), view.construct, view.provenance)


__all__ = ["LIMITED_EQUIVALENCE_ANNOTATION", "SERVICE_TYPE_ANNOTATION",
           "SOURCE_SERVICE_TYPE_ANNOTATION", "ConstructView", "StatusAnswer", "derive_construct",
           "describe", "read_status"]
