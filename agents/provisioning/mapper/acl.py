"""The mapper's access-list half (T111; contracts/construct-vocabulary.md §3.1 §5,
acl-render-contract.md §2 §3; FR-035 to FR-041, FR-097; AD-47).

An ``acl`` is optional on any construct and required on ``service_type: acl``. Two passes, both in
code, whatever the model said:

1. :func:`prepare` — **before** schema validation, on the model's raw JSON. The operator spellings
   of the address family (``l3``, ``ip`` → ``ipv4``; ``l3v6``, ``ipv6`` → ``ipv6``) are folded;
   what the published schema cannot carry is refused here, by name, instead of failing schema
   validation with a message that states neither the scope nor the range: a Layer 2 (``mac``) list
   — out of this construct's declared scope, **never** "the device lacks it" (the device offers
   ``type mac``; FR-038) — and a priority outside ``1-65534``, stated with the evaluation order and
   the usable range (FR-039, FR-040). The offending values are replaced by schema-valid stand-ins
   so the refused interpretation still validates; the causes carry the operator's own values and a
   refusal is never submitted.
2. :func:`review_acl` — after validation: distinct priorities and rule names, the reserved list
   names ``system`` and ``capture``, prefixes in the list's own address family, L4 ports only on
   TCP or UDP, and the informational ``evaluation_order`` / ``unmatched_traffic`` set from the
   declared default action — never from the model. The VLAN an ``acl`` endpoint names is a
   reference to another service's subinterface (AD-47): exempt from the naming band, held to the
   platform's VLAN space ``100-4000`` with both bands stated (:func:`reference_vlan_refusal`).

Egress against the qualification record is the stage's qualification pass (``agent.py``), which
refuses ``acl.stage`` by name when the record does not show ``acl.egress`` qualified (FR-097).
"""

from __future__ import annotations

import ipaddress
import re
from typing import Any

from common.schemas.interpretation import AclIntent

PRIORITY_MIN, PRIORITY_MAX = 1, 65534
RESERVED_PRIORITY = 65535
USABLE = "1\u201365534"
ORDER = "rules are evaluated in ascending priority number, first match wins"
RESERVED_NAMES = ("system", "capture")
L4_PROTOCOLS = ("tcp", "udp", 6, 17)
TYPE_FOLD = {"ipv4": "ipv4", "ip": "ipv4", "l3": "ipv4", "ip4": "ipv4", "inet": "ipv4",
             "ipv6": "ipv6", "l3v6": "ipv6", "ip6": "ipv6", "inet6": "ipv6"}
LAYER2_TYPES = ("mac", "l2", "ethernet", "layer2", "layer-2")
FAMILY_WORDS = "ipv4 or ipv6 (l3 and ip fold to ipv4, l3v6 to ipv6)"
REFERENCE_SPACE = (100, 4000)


def _fold_key(value: str) -> str:
    return value.strip().lower().replace(" ", "").replace("_", "-")


def fold_type(value: Any) -> str | None:
    """The address family an operator spelling names, or None when it names none."""
    if not isinstance(value, str):
        return None
    return TYPE_FOLD.get(_fold_key(value).replace("-", ""))


def priority_refusal(path: str, priority: int) -> str | None:
    """The cause for a rule priority outside the usable range, or None when it is usable."""
    if PRIORITY_MIN <= priority <= PRIORITY_MAX:
        return None
    if priority == RESERVED_PRIORITY:
        why = (f"{priority} is the reserved last position, which holds the default action and "
               "is never a rule's")
    else:
        why = f"{priority} is outside the usable priority range {USABLE}"
    return (f"{path}: {why}; {ORDER}, and a rule's priority must be one of {USABLE} "
            f"({RESERVED_PRIORITY} is reserved for the default action)")


# A match field the operator did not state is ABSENT (match anything), whatever placeholder the
# model wrote for it — T114 live finding: 'unknown' in destination_prefix/ports of an icmpv6 rule.
_OPTIONAL_MATCH = ("source_prefix", "destination_prefix", "source_port", "destination_port")
OPTIONAL_MATCH_PATH = re.compile(
    r"^acl\.rules(?:\[\d+\])?\.(?:source|destination)_(?:prefix|port)$")
_NOT_STATED = frozenset({"", "unknown", "any", "none", "null", "na", "n/a", "*", "unspecified",
                         "notstated", "notspecified", "not-stated", "not-specified"})


def prepare(data: dict[str, Any]) -> list[str]:
    """Pass 1, on the model's raw JSON (mutated in place). Returns the causes found."""
    acl = data.get("acl")
    if not isinstance(acl, dict):
        return []
    causes: list[str] = []
    raw_type = acl.get("type")
    folded = fold_type(raw_type)
    if folded is not None:
        acl["type"] = folded
    elif isinstance(raw_type, str) and _fold_key(raw_type) in LAYER2_TYPES:
        causes.append(
            f"acl.type: a Layer 2 ({raw_type}) access list is out of this platform's declared "
            "scope — the acl construct is defined over the IP address families, so a list is "
            f"{FAMILY_WORDS}; ask for an ipv4 or an ipv6 list")
        acl["type"] = "ipv4"  # stand-in: the request is refused
    elif isinstance(raw_type, str):
        causes.append(f"acl.type: '{raw_type}' is not an address family this construct carries; "
                      f"an access list is {FAMILY_WORDS}")
        acl["type"] = "ipv4"  # stand-in: the request is refused
    rules = acl.get("rules")
    if isinstance(rules, list):
        taken = {r.get("priority") for r in rules if isinstance(r, dict)}
        spare = PRIORITY_MAX
        for i, rule in enumerate(rules):
            if not isinstance(rule, dict):
                continue
            for key in _OPTIONAL_MATCH:  # a placeholder the model wrote for "not stated" is absent
                value = rule.get(key)
                if isinstance(value, str) and _fold_key(value) in _NOT_STATED:
                    del rule[key]
            priority = rule.get("priority")
            if type(priority) is not int:
                continue
            cause = priority_refusal(f"acl.rules[{i}].priority", priority)
            if cause is None:
                continue
            causes.append(cause)
            while spare in taken:  # an unused in-range stand-in: no second cause from it
                spare -= 1
            rule["priority"] = spare
            taken.add(spare)
    if causes:
        unsupported = data.get("unsupported_properties")
        data["unsupported_properties"] = [*(unsupported if isinstance(unsupported, list)
                                            else []), *causes]
    return causes


def _family_of(prefix: str) -> str | None:
    try:
        net = ipaddress.ip_network(prefix.strip(), strict=False)
    except ValueError:
        return None
    return f"ipv{net.version}"


def _port_problem(value: str) -> str | None:
    lo, _, hi = value.partition("-")
    first, last = int(lo), int(hi or lo)
    if first > 65535 or last > 65535:
        return f"'{value}' is not a port: ports are 0\u201365535"
    if first > last:
        return f"'{value}' is not a range: its start is above its end"
    return None


def review_acl(acl: AclIntent, *, family_refused: bool = False) -> tuple[dict[str, Any], list[str]]:
    """Pass 2, on the validated list. Returns the normalized wire form and the causes found;
    ``family_refused`` skips the family checks when pass 1 already refused the type."""
    causes: list[str] = []
    wire = acl.model_dump(mode="json", exclude_unset=True)
    if acl.name is not None and acl.name.strip().lower() in RESERVED_NAMES:
        causes.append(f"acl.name: '{acl.name}' is reserved on this platform for the device's "
                      "own system and packet-capture filters; name the list anything else")
    seen_priority: dict[int, int] = {}
    seen_name: dict[str, int] = {}
    for i, rule in enumerate(acl.rules):
        path = f"acl.rules[{i}]"
        if rule.priority in seen_priority:
            first = seen_priority[rule.priority]
            causes.append(
                f"{path}.priority: {rule.priority} is already the priority of rule "
                f"'{acl.rules[first].name}' (acl.rules[{first}]); priorities must be distinct — "
                f"{ORDER}, so which of the two decides would be arbitrary")
        else:
            seen_priority[rule.priority] = i
        if rule.name in seen_name:
            first = seen_name[rule.name]
            causes.append(f"{path}.name: rule '{rule.name}' is named twice (acl.rules[{first}] "
                          "and this one); rule names must be distinct within one list")
        else:
            seen_name[rule.name] = i
        for field in ("source_prefix", "destination_prefix"):
            prefix = getattr(rule, field)
            if prefix is None or family_refused:
                continue
            family = _family_of(prefix)
            if family is None:
                causes.append(f"{path}.{field}: '{prefix}' is not an IP prefix")
            elif family != acl.type:
                causes.append(f"{path}.{field}: {prefix} is an {family} prefix in an {acl.type} "
                              "access list; a prefix must be in the list's own address family, "
                              "or the entry would be programmed and never match")
        for field in ("source_port", "destination_port"):
            port = getattr(rule, field)
            if port is None:
                continue
            problem = _port_problem(port)
            if problem:
                causes.append(f"{path}.{field}: {problem}")
            if rule.protocol not in L4_PROTOCOLS:
                named = ("names no protocol" if rule.protocol is None
                         else f"is protocol {rule.protocol}")
                causes.append(f"{path}.{field}: a port match needs protocol tcp or udp, and rule "
                              f"'{rule.name}' {named}; the device matches L4 ports on TCP (6) "
                              "and UDP (17) only")
    for i, rule in enumerate(wire.get("rules") or []):
        if rule.get("protocol") == "icmpv6":
            wire["rules"][i]["protocol"] = "icmp6"  # the device's own spelling
    wire["evaluation_order"] = "ascending-first-match"
    wire["unmatched_traffic"] = acl.default_action or "accept-platform-default"
    return wire, causes


def reference_vlan_refusal(path: str, vlan: int) -> str | None:
    """The cause for a VLAN an ``acl`` endpoint names outside the platform's VLAN space (AD-47),
    or None. It is a reference to a subinterface that exists, named or allocated alike."""
    lo, hi = REFERENCE_SPACE
    if lo <= vlan <= hi:
        return None
    return (f"{path}: {vlan} lies outside the VLAN space 100\u20134000 this platform uses — the "
            "naming band 100\u2013999 an operator names from and the allocation band "
            "1000\u20134000 the allocation authority hands out — so no service's subinterface "
            "carries it; name the VLAN of the subinterface to bind, or none for the untagged "
            "subinterface")


__all__ = ["LAYER2_TYPES", "ORDER", "PRIORITY_MAX", "PRIORITY_MIN", "RESERVED_NAMES",
           "RESERVED_PRIORITY", "TYPE_FOLD", "USABLE", "fold_type", "prepare",
           "priority_refusal", "reference_vlan_refusal", "review_acl"]
