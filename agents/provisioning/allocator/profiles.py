"""Per-construct claim profiles and the normalized service intent (T099; contracts/
kuid-claim-profiles.md §2, §5; data-model.md §9, §10; AD-32, AD-33, AD-42, AD-51).

========== ====================================== ==========================================
construct  claims                                  derived, shown as rendered
========== ====================================== ==========================================
vlan       VLAN — only when none was named         —
mac-vrf    VLAN (unless named) + L2VNI             route targets ``target:<fabricASN>:<l2vni>``
           (+ L3VNI with an anycast gateway)
ip-vrf     L3VNI — **never a VLAN** (AD-51)        route targets ``target:<fabricASN>:<l3vni>``;
                                                   each endpoint's routed instance ``vrf-<sid>``
acl        nothing                                 —
========== ====================================== ==========================================

Every claim is named by the provider's one adoption scheme ``<intent-namespace>.migr-<sid>.<role>``
— role ``vlan-<entry>`` (entry = the ``vlans[]`` entry ``vlan-<sid>`` or the ``bridgeDomains[]``
entry ``bd-<sid>``), ``l2vni-bd-<sid>`` or ``l3vni-vrf-<sid>`` — and labelled in
``metadata.labels`` with the thread's correlation identifier and the tier.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from common.schemas.interpretation import Interpretation
from common.schemas.normalized_service_intent import NormalizedServiceIntent
from provisioning.allocator.kuid_adapter import VLAN, VNI

INTENT_NAMESPACE = "agentic-netops-intent"
CORRELATION_LABEL = "agentic-netops.io/correlation-id"
TIER_LABEL = "agentic-netops.io/tier"
TIER = "intent"
NAMING_BAND = (100, 999)
ALLOCATION_BAND = (1000, 4000)
NAMING = "100\u2013999"
ALLOCATION = "1000\u20134000"

# field of the assignment a claim fills
FIELD_VLAN = "vlan"
FIELD_L2VNI = "l2vni"
FIELD_L3VNI = "l3vni"


class ProfileError(ValueError):
    """The interpretation cannot be allocated as it stands (a contract violation between stages)."""


@dataclass(frozen=True)
class PlannedClaim:
    kind: str  # VLAN | VNI
    field: str  # vlan | l2vni | l3vni
    name: str


def network_name(service_id: str) -> str:
    return f"migr-{service_id}"


def entry_names(service_id: str) -> dict[str, str]:
    """The entry names the translator emits (network-spec.md §2)."""
    return {"vlans": f"vlan-{service_id}", "bridgeDomains": f"bd-{service_id}",
            "routers": f"vrf-{service_id}"}


def claim_name(service_id: str, role: str) -> str:
    return f"{INTENT_NAMESPACE}.{network_name(service_id)}.{role}"


def labels(correlation_id: str) -> dict[str, str]:
    return {CORRELATION_LABEL: correlation_id, TIER_LABEL: TIER}


def named_vlan(interp: Interpretation) -> int | None:
    """The one VLAN a ``vlan``/``mac-vrf`` names, or None. Two different ones are a
    contradiction in the request, never silently resolved."""
    named = sorted({e.vlan for e in interp.endpoints if e.vlan is not None})
    if len(named) > 1:
        raise ProfileError(
            f"endpoints[].vlan: the interpretation names VLANs {', '.join(map(str, named))}; a "
            f"{interp.service_type} is one broadcast domain, so every endpoint shares one VLAN")
    return named[0] if named else None


def check(interp: Interpretation) -> None:
    """What the allocator refuses to allocate from, whatever the mapper did."""
    if interp.missing_fields or interp.unsupported_properties:
        raise ProfileError("the interpretation is a clarification or a refusal, not an "
                           "interpretation to allocate for")
    if interp.service_type == "acl":
        return
    for i, e in enumerate(interp.endpoints):
        if e.vlan is not None and not NAMING_BAND[0] <= e.vlan <= NAMING_BAND[1]:
            raise ProfileError(
                f"endpoints[{i}].vlan: {e.vlan} is a named VLAN outside the naming band "
                f"{NAMING} (the allocation band {ALLOCATION} is the allocation authority's to "
                "hand out); a "
                "named VLAN is never claimed")
    if interp.service_type in ("vlan", "mac-vrf"):
        named_vlan(interp)


def plan(interp: Interpretation) -> list[PlannedClaim]:
    """The claims the construct's profile makes, in a fixed order."""
    sid = interp.service_id
    entries = entry_names(sid)
    claims: list[PlannedClaim] = []
    match interp.service_type:
        case "vlan":
            if named_vlan(interp) is None:
                claims.append(PlannedClaim(VLAN, FIELD_VLAN,
                                           claim_name(sid, f"vlan-{entries['vlans']}")))
        case "mac-vrf":
            if named_vlan(interp) is None:
                claims.append(PlannedClaim(VLAN, FIELD_VLAN,
                                           claim_name(sid, f"vlan-{entries['bridgeDomains']}")))
            claims.append(PlannedClaim(VNI, FIELD_L2VNI,
                                       claim_name(sid, f"l2vni-{entries['bridgeDomains']}")))
            if interp.anycast_gateway is not None:
                claims.append(PlannedClaim(VNI, FIELD_L3VNI,
                                           claim_name(sid, f"l3vni-{entries['routers']}")))
        case "ip-vrf":
            claims.append(PlannedClaim(VNI, FIELD_L3VNI,
                                       claim_name(sid, f"l3vni-{entries['routers']}")))
        case "acl":
            pass
    return claims


def route_targets(fabric_asn: int, vni: int) -> dict[str, list[str]]:
    target = f"target:{fabric_asn}:{vni}"
    return {"importRT": [target], "exportRT": [target]}


def _acl(interp: Interpretation) -> dict[str, Any] | None:
    if interp.acl is None:
        return None
    a = interp.acl.model_dump(mode="json", exclude_none=True)
    out: dict[str, Any] = {}
    for src, dst in (("name", "name"), ("stage", "stage"), ("type", "type"),
                     ("default_action", "defaultAction"), ("evaluation_order", "evaluationOrder"),
                     ("unmatched_traffic", "unmatchedTraffic")):
        if src in a:
            out[dst] = a[src]
    rules = []
    for r in a["rules"]:
        rule: dict[str, Any] = {}
        for src, dst in (("name", "name"), ("priority", "priority"), ("action", "action"),
                         ("protocol", "protocol"), ("source_prefix", "sourcePrefix"),
                         ("destination_prefix", "destinationPrefix"),
                         ("source_port", "sourcePort"), ("destination_port", "destinationPort"),
                         ("description", "description")):
            if src in r:
                rule[dst] = r[src]
        rules.append(rule)
    out["rules"] = rules
    return out


def build(interp: Interpretation, values: dict[str, int],
          fabric_asn: int | None) -> NormalizedServiceIntent:
    """The assignment from the interpretation and the claimed values (by field). Pure: the same
    inputs give the same object, byte for byte once serialized."""
    sid = interp.service_id
    kind = interp.service_type
    body: dict[str, Any] = {"serviceId": sid, "type": kind, "tenant": interp.tenant}
    endpoints: list[dict[str, Any]] = []
    if kind in ("vlan", "mac-vrf"):
        vlan = named_vlan(interp)
        if vlan is None:
            vlan = values[FIELD_VLAN]
        for e in interp.endpoints:
            endpoints.append({"node": e.site_or_node, "attachment": e.attachment, "vlan": vlan})
    elif kind == "ip-vrf":
        vrf = entry_names(sid)["routers"]
        for e in interp.endpoints:
            ep: dict[str, Any] = {"node": e.site_or_node, "attachment": e.attachment}
            if e.vlan is not None:
                ep["vlan"] = e.vlan  # named, carried as named; absent = untagged (AD-51)
            ep["vrf"] = vrf
            endpoints.append(ep)
    else:
        for e in interp.endpoints:
            ep = {"node": e.site_or_node, "attachment": e.attachment}
            if e.vlan is not None:
                ep["vlan"] = e.vlan  # a reference to another service's subinterface (AD-47)
            endpoints.append(ep)
    if kind == "mac-vrf":
        if fabric_asn is None:
            raise ProfileError("no fabricASN: route targets cannot be derived")
        body["routeTargets"] = route_targets(fabric_asn, values[FIELD_L2VNI])
        body["l2vni"] = values[FIELD_L2VNI]
        if interp.anycast_gateway is not None:
            body["l3vni"] = values[FIELD_L3VNI]
            gw: dict[str, Any] = {}
            if interp.anycast_gateway.ipv4:
                gw["gatewayIPv4"] = interp.anycast_gateway.ipv4
            if interp.anycast_gateway.ipv6:
                gw["gatewayIPv6"] = interp.anycast_gateway.ipv6
            body["anycastGateway"] = gw
    elif kind == "ip-vrf":
        if fabric_asn is None:
            raise ProfileError("no fabricASN: route targets cannot be derived")
        body["routeTargets"] = route_targets(fabric_asn, values[FIELD_L3VNI])
        body["l3vni"] = values[FIELD_L3VNI]
        families: dict[str, Any] = {}
        if interp.ipv4_prefixes:
            families["ipv4Prefixes"] = list(interp.ipv4_prefixes)
        if interp.ipv6_prefixes:
            families["ipv6Prefixes"] = list(interp.ipv6_prefixes)
        body["addressFamilies"] = families
    acl = _acl(interp)
    if acl is not None:
        body["acl"] = acl
    body["endpoints"] = endpoints
    return NormalizedServiceIntent.parse(body)


__all__ = ["ALLOCATION_BAND", "CORRELATION_LABEL", "INTENT_NAMESPACE", "NAMING_BAND", "TIER",
           "TIER_LABEL", "PlannedClaim", "ProfileError", "build", "check", "claim_name",
           "entry_names", "labels", "named_vlan", "network_name", "plan", "route_targets"]
