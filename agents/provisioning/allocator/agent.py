"""The allocator stage (T099; contracts/kuid-claim-profiles.md, data-model.md §9, §25; FR-056,
FR-060, FR-062, FR-063, FR-075, FR-104, FR-109; AD-16, AD-32, AD-33, AD-42, AD-51).

Skill ``allocate-network-service``:

* ``{"operation": "create", "interpretation": {...}}`` → data = the
  :class:`~common.schemas.normalized_service_intent.NormalizedServiceIntent` wire object. The
  construct's profile (:mod:`.profiles`) says which claims to make; each is created against the
  allocation authority (:mod:`.kuid_adapter`) under its deterministic name, labelled with the
  request's correlation identifier, and read back once bound. **Memoized by the claims
  themselves**: a repeat for the same correlation identifier finds its claims by label and name
  and returns the byte-identical assignment. A claim name already held under another correlation
  identifier is a second service under an existing name, and is refused naming the earlier one.
  A refusal (a stated value held, the pool exhausted) fails the request naming the value; an
  unreachable authority is retried by the bounded rule and then fails naming the authority —
  there is no local lease. On any failure the claims this call created are released.
* ``{"operation": "release", "correlation_ids": [...]}`` → ``{"released": [...],
  "correlation_ids": [...]}``: every claim carrying one of those correlation labels is deleted;
  "nothing claimed" is a success. Whether a service was *submitted* is the deployer's question
  (its release gate) and never the allocator's: this stage issues no read of any ``Network``.
"""

from __future__ import annotations

import json
import logging
import re
from collections.abc import Callable, Mapping
from pathlib import Path
from typing import Any

from a2a.types import Message
from pydantic import ValidationError

from common.schemas.interpretation import Interpretation
from common.schemas.normalized_service_intent import MARKER, NormalizedServiceIntent
from common.transport import StageMessage, reply_failed, reply_ok
from config.settings import Settings
from provisioning.allocator import profiles
from provisioning.allocator.kuid_adapter import (
    VLAN,
    AllocationError,
    AuthorityConfig,
    Claim,
    ClaimAdapter,
    ClaimExists,
    KubeClient,
)

log = logging.getLogger("agentic_netops.allocator")

INVENTORY_FILE = "inventory.json"
_LABEL_VALUE = re.compile(r"^[A-Za-z0-9]([-A-Za-z0-9_.]{0,61}[A-Za-z0-9])?$")


def load_fabric_asn(inventory_dir: Path, env: Mapping[str, str]) -> int | None:
    """``fabricASN`` of the site inventory, else ``FABRIC_ASN``; None when neither states it."""
    try:
        raw = json.loads((Path(inventory_dir) / INVENTORY_FILE).read_text(encoding="utf-8"))
        value = raw.get("fabricASN") if isinstance(raw, dict) else None
    except (OSError, ValueError):
        value = None
    if value is None:
        value = (env.get("FABRIC_ASN") or "").strip() or None
    if value is None:
        return None
    try:
        asn = int(value)
    except (TypeError, ValueError):
        return None
    return asn if 1 <= asn <= 4294967295 else None


class Allocator:
    """The allocator stage over one claim adapter."""

    def __init__(self, settings: Settings, *, adapter: ClaimAdapter | None = None,
                 adapter_factory: Callable[[], ClaimAdapter] | None = None) -> None:
        self.settings = settings
        self._adapter = adapter
        self._adapter_factory = adapter_factory

    def adapter(self) -> ClaimAdapter:
        if self._adapter is None:
            if self._adapter_factory is not None:
                self._adapter = self._adapter_factory()
            else:
                env = dict(self.settings.extra or {})
                self._adapter = ClaimAdapter(
                    AuthorityConfig.from_env(env), KubeClient(env=env),
                    retries=self.settings.worker_call_retries,
                    backoff=self.settings.worker_call_backoff_seconds)
        return self._adapter

    # ---- create -----------------------------------------------------------------------------

    async def _claim(self, adapter: ClaimAdapter, planned: profiles.PlannedClaim,
                     existing: dict[str, Claim], correlation_id: str,
                     created: list[profiles.PlannedClaim], interp: Interpretation) -> int:
        claim = existing.get(planned.name)
        if claim is None:
            try:
                claim = await adapter.create(planned.kind, planned.name,
                                             profiles.labels(correlation_id))
                created.append(planned)
            except ClaimExists:
                claim = await adapter.get(planned.kind, planned.name)
                if claim is None:
                    raise AllocationError(f"claim {planned.name} vanished while it was being "
                                          "created; nothing was assigned") from None
                holder = claim.labels.get(profiles.CORRELATION_LABEL, "")
                if holder != correlation_id:
                    raise AllocationError(
                        f"a service named {profiles.network_name(interp.service_id)} already "
                        f"exists: claim {planned.name} is held for correlation id "
                        f"{holder or '(unlabelled)'}; a second service under an existing name is "
                        "refused") from None
        claim = await adapter.wait_bound(claim)
        what = "VLAN" if planned.kind == VLAN else planned.field.upper()
        if claim.ready is False:
            value = f"{what} {claim.stated} " if claim.stated is not None else f"{what} "
            detail = f"{claim.reason}: {claim.message}".strip(": ")
            raise AllocationError(f"allocation refused: {value}claim {planned.name}: {detail}")
        value = claim.value
        if value is None:  # wait_bound never returns a bound claim without its value
            raise AllocationError(f"claim {planned.name} reports no allocated value")
        if planned.kind == VLAN and not (profiles.ALLOCATION_BAND[0] <= value
                                         <= profiles.ALLOCATION_BAND[1]):
            raise AllocationError(
                f"allocation refused: VLAN {value} bound to claim {planned.name} lies outside the "
                f"allocation band {profiles.ALLOCATION}; an allocated VLAN never comes from the "
                f"naming band {profiles.NAMING}")
        return value

    async def allocate(self, interp: Interpretation,
                       correlation_id: str) -> NormalizedServiceIntent:
        profiles.check(interp)
        planned = profiles.plan(interp)
        fabric_asn = load_fabric_asn(self.settings.site_inventory_dir, self.settings.extra or {})
        if interp.service_type in ("mac-vrf", "ip-vrf") and fabric_asn is None:
            raise AllocationError(
                f"the site inventory ({self.settings.site_inventory_dir}/{INVENTORY_FILE}) states "
                "no fabricASN, so the route targets target:<fabricASN>:<vni> cannot be derived; "
                "nothing was claimed")
        if not planned:
            return profiles.build(interp, {}, fabric_asn)  # "claims nothing" is a success
        adapter = self.adapter()
        existing = {c.name: c for c in await adapter.list(profiles.labels(correlation_id))}
        created: list[profiles.PlannedClaim] = []
        values: dict[str, int] = {}
        try:
            for p in planned:
                values[p.field] = await self._claim(adapter, p, existing, correlation_id,
                                                    created, interp)
            return profiles.build(interp, values, fabric_asn)
        except (AllocationError, profiles.ProfileError):
            for p in created:  # release what this call claimed: no partial assignment survives
                try:
                    await adapter.delete(p.kind, p.name)
                except AllocationError as exc:
                    log.warning("allocator: rollback of %s failed: %s", p.name, exc)
            raise

    # ---- release ----------------------------------------------------------------------------

    async def release(self, correlation_ids: list[str]) -> dict[str, Any]:
        adapter = self.adapter()
        released: list[str] = []
        for cid in correlation_ids:
            for claim in await adapter.list(profiles.labels(cid)):
                if await adapter.delete(claim.kind, claim.name):
                    released.append(claim.name)
        return {"released": released, "correlation_ids": list(correlation_ids)}

    # ---- the handler ------------------------------------------------------------------------

    async def handle(self, request: StageMessage) -> Message:
        payload = request.data if isinstance(request.data, dict) else {}
        operation = payload.get("operation") or request.operation or "create"
        try:
            if operation == "release":
                ids = payload.get("correlation_ids")
                if not isinstance(ids, list) or not all(
                        isinstance(i, str) and _LABEL_VALUE.match(i) for i in ids):
                    return reply_failed("payload.correlation_ids: a list of correlation "
                                        "identifiers is required")
                result = await self.release(ids)
                log.info("allocator: released %d claim(s) for %d correlation id(s)",
                         len(result["released"]), len(ids))
                return reply_ok(f"Released {len(result['released'])} claim(s).", result)
            if operation != "create":
                return reply_failed(f"operation {operation!r} is not the allocator's: it "
                                    "allocates (create) and releases (release)")
            cid = request.correlation_id
            if not isinstance(cid, str) or not _LABEL_VALUE.match(cid):
                return reply_failed("the request carries no correlation identifier to label its "
                                    "claims with; nothing was claimed")
            try:
                interp = Interpretation.parse(payload.get("interpretation"))
            except (ValidationError, TypeError, ValueError) as exc:
                return reply_failed(f"payload.interpretation is not a valid Interpretation: "
                                    f"{str(exc).splitlines()[0]}")
            intent = await self.allocate(interp, cid)
        except (AllocationError, profiles.ProfileError) as exc:
            log.warning("allocator: %s", exc)
            return reply_failed(str(exc))
        wire = intent.to_wire()
        return reply_ok(summary(intent, wire), wire)


def summary(intent: NormalizedServiceIntent, wire: dict[str, Any]) -> str:
    parts = [f"Assignment for {intent.type} {intent.serviceId} (tenant {intent.tenant}):"]
    vlans = sorted({e.vlan for e in intent.endpoints if e.vlan is not None})
    if vlans:
        parts.append(f"VLAN {', '.join(map(str, vlans))}")
    if intent.l2vni is not None:
        parts.append(f"L2VNI {intent.l2vni}")
    if intent.l3vni is not None:
        parts.append(f"L3VNI {intent.l3vni}")
    if intent.routeTargets is not None:
        parts.append(f"route targets import {', '.join(intent.routeTargets.importRT)} export "
                     f"{', '.join(intent.routeTargets.exportRT)}")
    text = " ".join(parts[:1]) + " " + "; ".join(parts[1:]) if len(parts) > 1 else parts[0]
    body = json.dumps(wire, separators=(",", ":"), sort_keys=True)
    return f"{text.strip()}.\n<!-- {MARKER}: {body} -->"


__all__ = ["Allocator", "load_fabric_asn", "summary"]
