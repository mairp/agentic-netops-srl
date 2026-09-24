"""Reading a live ``Network``'s conditions (T100; data-model.md §15 §17 §18, AD-40, AD-53, AD-62).

``Ready`` is read as the cluster reports it — the status **string** ``"True"``, ``"False"`` or
``"Unknown"`` and its reason — never coerced to a boolean. What is *terminal* comes from the
provider's closed reason set (api/fabric/v1alpha1/conditions.go) and its reconciler
(controllers/network/network_controller.go ``terminal``/``terminalReady``): a refusal at
``Accepted``, ``Rendered`` or ``Validated``, or ``Applied=False/OwnershipConflict``, at the object's
current generation. ``Ready=Unknown`` is never terminal and never converged (FR-107).
"""

from __future__ import annotations

import re
from collections.abc import Mapping
from dataclasses import dataclass
from typing import Any

from common.schemas.audit import ResourceRef
from provisioning.deployer.kube import API_VERSION, INTENT_NAMESPACE, KIND
from provisioning.deployer.stamp import SPEC_HASH_ANNOTATION, spec_sha256

READY = "Ready"
DELETING = "Deleting"
REASON_DELETING = "Deleting"
# (condition type, False reason) pairs the provider never retries without a new generation.
TERMINAL_FALSE_REASONS: dict[str, frozenset[str]] = {
    "Accepted": frozenset({"InvalidIntent", "ReferenceNotFound", "Unqualified",
                           "AllocationConflict"}),
    "Rendered": frozenset({"SchemaMismatch", "MappingFailed", "RegisterUncovered"}),
    "Validated": frozenset({"YangValidationFailed", "SchemaMismatch"}),
    "Applied": frozenset({"OwnershipConflict"}),
}
_UNREACHABLE = re.compile(r"unreachable:\s*([^;]+)")


def condition(obj: Mapping[str, Any] | None, ctype: str) -> dict[str, Any] | None:
    if not obj:
        return None
    for c in (obj.get("status") or {}).get("conditions") or []:
        if isinstance(c, dict) and c.get("type") == ctype:
            return c
    return None


@dataclass(frozen=True)
class Live:
    """One read of a live ``Network``."""

    name: str
    obj: Mapping[str, Any]

    @property
    def meta(self) -> Mapping[str, Any]:
        return self.obj.get("metadata") or {}

    @property
    def uid(self) -> str | None:
        return self.meta.get("uid")

    @property
    def deleting(self) -> bool:
        ready = condition(self.obj, READY)
        return bool(self.meta.get("deletionTimestamp")) or bool(
            ready and ready.get("status") == "False" and ready.get("reason") == REASON_DELETING)

    @property
    def ready(self) -> str | None:
        """``"True"``/``"False"``/``"Unknown"`` as reported, or ``None`` before any read."""
        c = condition(self.obj, READY)
        status = c.get("status") if c else None
        return status if status in ("True", "False", "Unknown") else None

    @property
    def reason(self) -> str | None:
        c = condition(self.obj, READY)
        if not c:
            return None
        return str(c.get("reason") or "") or (None if self.ready == "True" else "Unspecified")

    @property
    def ready_message(self) -> str:
        c = condition(self.obj, READY)
        return str((c or {}).get("message") or "")

    @property
    def deleting_condition(self) -> dict[str, Any] | None:
        return condition(self.obj, DELETING)

    def outstanding(self) -> str:
        """What the ``Deleting`` condition names as outstanding, in words."""
        c = self.deleting_condition
        if not c:
            return "finalization has not reported its progress yet"
        reason, message = str(c.get("reason") or ""), str(c.get("message") or "")
        m = _UNREACHABLE.search(message) if reason == "TargetUnreachable" else None
        if m:
            return f"waiting on {m.group(1).strip()} ({reason}): {message}"
        return f"Deleting={c.get('status')}/{reason}: {message}"

    def terminal(self) -> str | None:
        """The terminal refusal at the current generation, as ``Type=False/Reason: message``."""
        generation = self.meta.get("generation")
        for ctype, reasons in TERMINAL_FALSE_REASONS.items():
            c = condition(self.obj, ctype)
            if not c or c.get("status") != "False" or c.get("reason") not in reasons:
                continue
            observed = c.get("observedGeneration")
            if generation is not None and observed is not None and observed != generation:
                continue
            return f"{ctype}=False/{c.get('reason')}: {c.get('message') or ''}".rstrip(": ")
        return None

    @property
    def submitted_hash(self) -> str | None:
        return (self.meta.get("annotations") or {}).get(SPEC_HASH_ANNOTATION)

    @property
    def live_hash(self) -> str:
        return spec_sha256(self.obj.get("spec"))

    @property
    def modified(self) -> bool:
        return self.submitted_hash != self.live_hash

    def ref(self) -> ResourceRef:
        ready = self.ready
        return ResourceRef(apiVersion=API_VERSION, kind=KIND, namespace=INTENT_NAMESPACE,
                           name=self.name, uid=self.uid, ready=ready,
                           reason=self.reason if ready else None)

    def summary(self) -> dict[str, Any]:
        """The live state carried as ``live`` on a report."""
        conditions = [{k: c.get(k) for k in ("type", "status", "reason", "message") if
                       c.get(k) is not None}
                      for c in (self.obj.get("status") or {}).get("conditions") or []
                      if isinstance(c, dict)]
        out: dict[str, Any] = {"name": self.name, "namespace": INTENT_NAMESPACE,
                               "ready": self.ready, "reason": self.reason,
                               "conditions": conditions, "specSha256": self.live_hash,
                               "submittedSpecSha256": self.submitted_hash}
        if self.meta.get("deletionTimestamp"):
            out["deletionTimestamp"] = self.meta["deletionTimestamp"]
        return out


def network_ref(name: str, *, ready: str | None = None, reason: str | None = None,
                uid: str | None = None) -> ResourceRef:
    return ResourceRef(apiVersion=API_VERSION, kind=KIND, namespace=INTENT_NAMESPACE, name=name,
                       uid=uid, ready=ready, reason=reason)


__all__ = ["DELETING", "READY", "TERMINAL_FALSE_REASONS", "Live", "condition", "network_ref"]
