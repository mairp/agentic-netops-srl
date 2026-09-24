"""Deterministic request classification (T074; FR-050, FR-076, FR-028, SC-027, SC-028).

Every request is one of three classes — **provisionable**, **informational** or
**unsupported-or-unsafe** — decided by rules, never by a model call, so no phrasing can argue a
refusal away. The classifier runs on the operator text *after* :func:`neutralize`, so an
instruction embedded in the request is quarantined data and is neither obeyed nor classified
(FR-077).

Rule order, first match wins:

1. a request to skip, pre-approve or waive a confirmation → refused, ``confirmation-required``;
2. a request naming a tool or function to call → refused, ``unknown-tool``;
3. a request to act directly on a device (a session, a command, a shell, a configuration push)
   → refused, ``unsupported-or-unsafe``, naming the declarative equivalent (FR-076);
4. a question about the platform → informational;
5. a provisioning verb with a construct of contracts/construct-vocabulary.md (name resolution
   of §2, synonyms and migration aliases included) → provisionable;
6. a provisioning verb with anything else → refused, ``unsupported-construct``, listing the four;
7. otherwise → informational (answered with the vocabulary; nothing is proposed).
"""

from __future__ import annotations

import re
import unicodedata
from dataclasses import dataclass, field
from enum import StrEnum

from common.guards.injection import Finding, neutralize
from common.guards.refusals import (
    Refusal,
    RefusalClass,
    refuse_confirmation_bypass,
    refuse_direct_device_action,
    refuse_unknown_tool,
    refuse_unsupported_construct,
)


class RequestClass(StrEnum):
    PROVISIONABLE = "provisionable"
    INFORMATIONAL = "informational"
    UNSUPPORTED_OR_UNSAFE = "unsupported-or-unsafe"


# construct-vocabulary.md §2: the key function and the resolution table.
RESOLUTION: dict[str, str] = {
    "vlan": "vlan",
    "macvrf": "mac-vrf",
    "ipvrf": "ip-vrf",
    "acl": "acl",
    "l2vni": "mac-vrf",
    "l3vni": "ip-vrf",
    "accesslist": "acl",
    "vpls": "mac-vrf",
    "vpws": "mac-vrf",
    "eline": "mac-vrf",
    "l3vpn": "ip-vrf",
    "l2l3irb": "mac-vrf",
    "irb": "mac-vrf",
}


def construct_key(name: str) -> str:
    """construct-vocabulary.md §2: lowercase, then delete each ``-``, ``_``, space, ``.``, ``+``."""
    return re.sub(r"[-_ .+]", "", name.lower())


_CONSTRUCT_MENTION = re.compile(
    r"\b(mac[-_ .]?vrf|ip[-_ .]?vrf|l2vni|l3vni|access[-_ ]?list|acl|vpls|vpws|e[-_ ]?line"
    r"|l3vpn|l2l3[-_ ]?irb|irb|vlan)\b(?!\s*[-=:]?\s*\d)"
)

# Rule 1 — waiving a confirmation.
_CONFIRMATION_BYPASS = re.compile(
    r"\b(?:skip|bypass|waive|omit|without|no need for|don'?t (?:ask|wait) for|do not (?:ask|wait)"
    r" for)\b[^.\n]{0,30}\b(?:confirm\w*|approv\w*|review|asking me)"
    r"|\b(?:auto-?(?:confirm|approve)\w*|pre-?(?:confirm|approv)\w*)"
    r"|\b(?:i(?: have|'ve)? already (?:confirmed|approved)"
    r"|consider (?:it|this) (?:confirmed|approved)"
    r"|treat (?:it|this) as (?:confirmed|approved)|mark (?:it|this|the \w+) (?:as )?"
    r"(?:confirmed|approved))"
    r"|\bconfirm(?:ation)?\s*[:=]\s*(?:yes|true|y)\b"
)

# Rule 2 — tool-name confusion.
_TOOL_REQUEST = re.compile(
    r"\b(?:call|invoke|use|trigger|run|execute)\b[^.\n]{0,40}\b(?:tool|function|endpoint|api)s?\b"
    r"|\b[a-z][a-z0-9]*_[a-z0-9_]+\s*\("
    r"|\b(?:tool_call|function_call)\b"
    r"|\b(?:call|invoke)\s+(?:the\s+)?(?:deployer|allocator|mapper|supervisor|kubectl|gnmi\w*)\b"
)

# Rule 3 — acting directly on a device.
_DEVICE_ACTION = re.compile(
    r"\b(?:ssh|telnet|scp|sftp|netconf|sr_cli|gnmic|clab|containerlab|console)\b"
    r"|\bgnmi\b[^.\n]{0,30}\b(?:set|push|write|replace|update)\b"
    r"|\b(?:set|push|write|replace|update|apply|send|deploy|load|paste)\b[^.\n]{0,40}"
    r"\b(?:config(?:uration)?|cli|commands?|json|yaml)\b[^.\n]{0,40}\b(?:to|on|onto|into)\b"
    r"[^.\n]{0,20}\b(?:leaf|spine|node|device|switch|router)\w*"
    r"|\b(?:via|over|through|with|using)\s+gnmi\b"
    r"|\b(?:bash|shell|sh -c|root prompt|cli)\b"
    r"|\b(?:log|logging)\s*(?:in|on)(?:to)?\b|\blogin\b"
    r"|\b(?:docker|kubectl|podman)\s+exec\b|\bexec\s+into\b"
    r"|`[^`]+`"
    r"|\bshow\s+(?:network-instance|interface|version|system|platform|running|config\w*|arp"
    r"|mac|tunnel|bgp|route|acl|lldp)\b"
    r"|\b(?:enter candidate|commit now|commit stay|diff flat)\b"
    r"|\b(?:reboot|reload|power[- ]cycle|factory[- ]reset)\b"
    r"|\bdirectly on\b|\bon the (?:device|box|switch) (?:directly|itself)\b"
    r"|\bby hand\b|\bmanually (?:configure|add|set|fix)\b|\byourself\b"
)

# A protocol an access-list rule MATCHES is traffic, not a session this tier would open: a rule
# name carrying it ("deny-telnet", "allow-ssh") and a filter verb applied to it ("denies telnet",
# "block ssh traffic") are removed before Rule 3 looks. "telnet to leaf02 …" is untouched.
_FILTERED_PROTOCOL = re.compile(
    r"\b[a-z0-9]+(?:-[a-z0-9]+)*-(?:ssh|telnet)\b|\b(?:ssh|telnet)(?:-[a-z0-9]+)+\b"
    r"|\b(?:deny|denies|permit|permits|allow|allows|block|blocks|drop|drops|match|matches)"
    r"\s+(?:tcp\s+)?(?:ssh|telnet)\b(?!\s+(?:to|into|on|onto)\b)"
    r"|\b(?:ssh|telnet)\s+traffic\b"
)

# Rule 4 — a question about the platform.
_QUESTION = re.compile(
    r"^(?:what|which|why|how|when|where|who|can|could|does|do|is|are|explain|describe|tell me"
    r"|list|help|show me (?:the )?(?:constructs|options|vocabulary|help))\b"
)

# Rule 5 — provisioning verbs.
_PROVISION = re.compile(
    r"\b(?:create|add|provision|build|set up|setup|make|declare|extend|stretch|attach|connect"
    r"|migrate|need|want|give me|deploy|remove|delete|tear down|decommission|change|modify"
    r"|bind|filter|allow|deny|block|permit|route)\b"
)

_UNSUPPORTED_NOUN = re.compile(r"\b(?:create|add|provision|build|make|deploy|need|want)\s+"
                               r"(?:an?\s+|the\s+|some\s+)?([a-z0-9][a-z0-9-]*)")

_ENDPOINT = re.compile(r"\b((?:leaf|spine|border|node)[a-z0-9-]*\d)\s*[:/ ]\s*(ethernet-\d+/\d+)\b")
_VLAN = re.compile(r"\bvlan\s*[-=:]?\s*(\d{1,4})\b")
_TENANT = re.compile(r"\btenant\s+([a-z0-9][a-z0-9-]*)")


@dataclass(frozen=True)
class Classification:
    request_class: RequestClass
    refusal: Refusal | None = None
    construct: str | None = None
    quarantined: tuple[Finding, ...] = field(default=())

    @property
    def refusal_class(self) -> RefusalClass | None:
        """The refusal class, or ``injection-quarantined`` when only an instruction was removed."""
        if self.refusal is not None:
            return self.refusal.refusal_class
        if self.quarantined:
            return RefusalClass.INJECTION_QUARANTINED
        return None


def _fold(text: str) -> str:
    return unicodedata.normalize("NFKC", text).casefold()


def resolve_construct(text: str) -> str | None:
    """The construct a request names, by the vocabulary's name resolution; ``None`` if none."""
    for match in _CONSTRUCT_MENTION.finditer(_fold(text)):
        construct = RESOLUTION.get(construct_key(match.group(1)))
        if construct is not None:
            return construct
    # A bare "vlan 200" still names the vlan construct when nothing else is named.
    if _VLAN.search(_fold(text)):
        return "vlan"
    return None


def extract_fields(text: str) -> dict[str, object]:
    """The request fields the guard layer can read deterministically (not the mapper's job)."""
    folded = _fold(text)
    vlan = _VLAN.search(folded)
    tenant = _TENANT.search(folded)
    return {
        "construct": resolve_construct(text),
        "endpoints": [{"node": n, "attachment": a} for n, a in _ENDPOINT.findall(folded)],
        "tenant": tenant.group(1) if tenant else None,
        "vlan": int(vlan.group(1)) if vlan else None,
    }


def _classify_kept(text: str) -> tuple[RequestClass, Refusal | None, str | None]:
    folded = _fold(text).strip()
    named = resolve_construct(text)
    if _CONFIRMATION_BYPASS.search(folded):
        return RequestClass.UNSUPPORTED_OR_UNSAFE, refuse_confirmation_bypass(named), None
    if _TOOL_REQUEST.search(folded):
        return RequestClass.UNSUPPORTED_OR_UNSAFE, refuse_unknown_tool(named), None
    if _DEVICE_ACTION.search(_FILTERED_PROTOCOL.sub(" ", folded)):
        return RequestClass.UNSUPPORTED_OR_UNSAFE, refuse_direct_device_action(named), None
    if _QUESTION.search(folded) or folded.endswith("?"):
        return RequestClass.INFORMATIONAL, None, None
    if _PROVISION.search(folded):
        if named is not None:
            return RequestClass.PROVISIONABLE, None, named
        noun = _UNSUPPORTED_NOUN.search(folded)
        return (
            RequestClass.UNSUPPORTED_OR_UNSAFE,
            refuse_unsupported_construct(noun.group(1) if noun else None),
            None,
        )
    return RequestClass.INFORMATIONAL, None, None


def classify(text: str) -> Classification:
    """Classify an operator request; embedded instructions are quarantined first (FR-077)."""
    kept, quarantined = neutralize(text, "operator")
    request_class, refusal, construct = _classify_kept(kept)
    return Classification(request_class, refusal, construct, quarantined)
