"""Refusals that name the declarative equivalent (T074; FR-076, FR-028, SC-028).

Every refusal the guards give is phrased in the construct vocabulary of
contracts/construct-vocabulary.md — ``vlan``, ``mac-vrf``, ``ip-vrf``, ``acl`` — and points at the
one supported path: *a Network submitted through the intent tier*, confirmed twice. A refusal
never names a device command, a device session or a tool the tier does not offer, so that the
answer to "do it on the device" is never a recipe for doing it on the device.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import StrEnum

# Contract order (construct-vocabulary.md §1): reported to an operator in exactly this order.
CONSTRUCTS: tuple[str, ...] = ("vlan", "mac-vrf", "ip-vrf", "acl")

# One line per construct, from construct-vocabulary.md §1.
CONSTRUCT_SUMMARY: dict[str, str] = {
    "vlan": "a local broadcast domain: a VLAN and the ports in it",
    "mac-vrf": "a VLAN extended over the fabric by an L2VNI with EVPN route targets",
    "ip-vrf": "a routed instance: a VRF with an L3VNI and route targets",
    "acl": "a filter bound to the attachment subinterfaces a service occupies",
}

# What the operator states for each construct (construct-vocabulary.md §3, the R rows).
CONSTRUCT_INPUTS: dict[str, str] = {
    "vlan": "its tenant and its endpoints (node and attachment) with the shared VLAN",
    "mac-vrf": "its tenant and at least two endpoints (node and attachment)",
    "ip-vrf": "its tenant, its endpoints with their VRF and at least one address family",
    "acl": "its tenant, the attachments it binds to and its rules",
}

SUBMISSION = "a Network submitted through the intent tier"


class RefusalClass(StrEnum):
    """The closed set of refusal classes the guards and the adversarial corpus share."""

    UNSUPPORTED_OR_UNSAFE = "unsupported-or-unsafe"
    UNSUPPORTED_CONSTRUCT = "unsupported-construct"
    CONFIRMATION_REQUIRED = "confirmation-required"
    UNKNOWN_TOOL = "unknown-tool"
    INJECTION_QUARANTINED = "injection-quarantined"


@dataclass(frozen=True)
class Refusal:
    """A refusal: its class, the operator-facing message and the construct it points at."""

    refusal_class: RefusalClass
    message: str
    equivalent: str | None = None


def declarative_equivalent(construct: str | None) -> str:
    """The supported declarative equivalent, in construct vocabulary."""
    if construct in CONSTRUCT_SUMMARY:
        return (
            f"declare a {construct} ({CONSTRUCT_SUMMARY[construct]}), stating "
            f"{CONSTRUCT_INPUTS[construct]}, as {SUBMISSION}"
        )
    listed = "; ".join(f"{c} ({CONSTRUCT_SUMMARY[c]})" for c in CONSTRUCTS)
    return f"declare one of the four constructs — {listed} — as {SUBMISSION}"


def refuse_direct_device_action(construct: str | None = None) -> Refusal:
    """FR-076: a request to act directly on a device is refused, naming the equivalent."""
    message = (
        "Refused: this tier never acts directly on a device — it opens no session to one, runs "
        "no command on one and pushes no configuration to one. The supported equivalent is to "
        f"{declarative_equivalent(construct)}; it is shown to you and confirmed twice before "
        "anything is written, and the fabric then reconciles it."
    )
    return Refusal(RefusalClass.UNSUPPORTED_OR_UNSAFE, message, construct)


def refuse_confirmation_bypass(construct: str | None = None) -> Refusal:
    """Both confirmation points are always presented; neither can be waived by request text."""
    message = (
        "Refused: both confirmations — of the interpretation, and of the assignment before "
        "submission — are always presented and cannot be skipped, pre-approved or waived in the "
        f"request text. To proceed, {declarative_equivalent(construct)}, and confirm at each "
        "point when it is shown to you."
    )
    return Refusal(RefusalClass.CONFIRMATION_REQUIRED, message, construct)


def refuse_unknown_tool(construct: str | None = None) -> Refusal:
    """A request naming a tool or function is refused: the tier's stages are not operator tools."""
    message = (
        "Refused: the tier offers no tool, function or agent an operator can call by name; its "
        "stages run in a fixed order behind two confirmations. The supported equivalent is to "
        f"{declarative_equivalent(construct)}."
    )
    return Refusal(RefusalClass.UNKNOWN_TOOL, message, construct)


def refuse_unsupported_construct(named: str | None = None) -> Refusal:
    """FR-028: a construct outside the vocabulary is refused with the four construct names."""
    what = f"'{named}' is not a construct this platform offers" if named else (
        "the request names no construct this platform offers"
    )
    message = (
        f"Refused: {what}. The constructs are {', '.join(CONSTRUCTS)}. "
        f"To proceed, {declarative_equivalent(None)}."
    )
    return Refusal(RefusalClass.UNSUPPORTED_CONSTRUCT, message, None)
