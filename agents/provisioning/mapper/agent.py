"""The mapper stage (T098; data-model.md §8, contracts/construct-vocabulary.md,
kuid-claim-profiles.md §2 rule 1; FR-058, FR-059, FR-061, FR-062, FR-034, FR-097, CR-003;
AD-41, AD-47, AD-51, AD-56, AD-61, AD-68).

Skill ``map-network-request``: payload ``{"text": str, "operation": "create"}`` → data = an
:class:`~common.schemas.interpretation.Interpretation`.

Two halves, in this order:

1. **Interpretation by the model** — the prompt of :mod:`.prompts` (operator text as delimited
   data, construct vocabulary only), the JSON object extracted from the answer and validated
   strictly against the published schema. Schema-invalid output gets exactly one corrective retry;
   a second invalid answer fails the stage naming schema-invalid model output.
2. **Deterministic review, in code**, whatever the model said:

   * ``service_id`` is generated here — the first 15 lower-case hex characters of a random
     version-4 UUID (data-model.md §8, AD-61) — never the model's, never built from the tenant;
   * the **naming band**: a VLAN named on a ``vlan``, ``mac-vrf`` or ``ip-vrf`` endpoint outside
     ``100-999`` is refused stating both bands and that ``1000-4000`` is the allocation authority's
     to hand out (AD-41) — the schema floors a VLAN at 0 with no upper bound precisely so this
     stage, not schema validation, answers (AD-61). The VLAN a standalone ``acl`` names is a
     reference to another service's subinterface and is exempt (AD-47);
   * an ``ip-vrf`` endpoint that names no VLAN is the untagged subinterface, never a missing
     field (AD-51);
   * node and port against the site inventory, valid names enumerated; spines are never
     attachment points;
   * the declared tagging mode of each port (``untaggedAccessPorts``, CR-003, AD-68): an endpoint
     asking for the other mode is refused listing the ports declared in the mode it asked for;
   * the anycast gateway, a property of ``mac-vrf`` (T117; FR-032, CR-002): **only the declared
     address families** — a gateway family whose address the operator never wrote is dropped,
     never added (addresses compared by value, so ``2001:DB8::1`` and ``2001:db8:0::1`` are the
     same); when none remains, a gateway the operator asked for is a missing field and one the
     request never mentions is removed (no routed instance, no L3 identifier);
   * the qualification record: an unqualified construct or gated property refused by name (FR-097)
     — an egress access list among them, refused by name unless ``acl.egress`` is qualified, and
     each declared gateway family by the key the catalogue gives it (CR-010);
   * an ``acl`` — optional on any construct, required on ``service_type: acl`` — reviewed by
     :mod:`.acl` (T111): the address family folded and a Layer 2 list refused as out of scope,
     priorities distinct and in ``1-65534`` stated with the evaluation order (ascending priority,
     first match wins), rule names distinct, the reserved names ``system``/``capture``, prefixes
     in the list's own family, L4 ports on TCP/UDP only; an ``acl`` endpoint's VLAN held to
     ``100-4000`` (FR-035 to FR-041);
   * one construct per request; unsupported claims named; missing or ambiguous fields asked for
     by exact path, never defaulted.

   Refusals ride in ``unsupported_properties`` as complete causes, property path first; they and
   ``missing_fields`` are mutually exclusive, the refusal winning. The mapper never claims
   anything.
"""

from __future__ import annotations

import asyncio
import ipaddress
import json
import logging
import re
import uuid
from collections.abc import Callable, Iterable
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Protocol

from a2a.types import Message
from pydantic import ValidationError

from common import tracing
from common.guards.redaction import redact
from common.schemas.interpretation import MARKER, Interpretation
from common.transport import StageMessage, reply_failed, reply_ok
from config.settings import Settings
from provisioning.mapper import acl as acl_mod
from provisioning.mapper import catalogue as catalogue_mod
from provisioning.mapper import prompts
from provisioning.mapper.catalogue import CONSTRUCTS, Catalogue

log = logging.getLogger("agentic_netops.mapper")

NAMING_BAND = (100, 999)
ALLOCATION_BAND = (1000, 4000)
NAMING = "100\u2013999"
ALLOCATION = "1000\u20134000"
SPACE = "100\u20134000"
PLACEHOLDER = "unknown"
INVENTORY_FILE = "inventory.json"
QUALIFIED = "qualified"
ALIAS_CONSTRUCT = {"VPLS": "mac-vrf", "VPWS": "mac-vrf", "L2L3-IRB": "mac-vrf", "L3VPN": "ip-vrf"}
_PORT = re.compile(r"^(?:ethernet|eth|et|e)[-_ ]?(\d+)\s*[/_-]\s*(\d+)$")
_ADDRESS_TOKEN = re.compile(r"[0-9A-Fa-f:.]+")
_GATEWAY_WORDS = re.compile(r"gateway|anycast|\bgw\b|\birb\b|l2l3", re.IGNORECASE)


class ModelClient(Protocol):
    def complete(self, messages: list[dict[str, Any]]) -> Any: ...


class MapperFailure(Exception):
    """A terminal failure of the stage (reply_failed)."""


# --------------------------------------------------------------------------------------------------
# the one rule of data-model.md §8 (AD-61)
# --------------------------------------------------------------------------------------------------


def generate_service_id() -> str:
    """15 characters of ``[0-9a-f]``: the first 15 of a random version-4 UUID's hex form. Opaque —
    it takes no argument, so nothing of the request (the tenant least of all) can shape it."""
    return uuid.uuid4().hex[:15]


# --------------------------------------------------------------------------------------------------
# mounted inputs
# --------------------------------------------------------------------------------------------------


@dataclass(frozen=True)
class Node:
    name: str
    role: str
    access_ports: tuple[str, ...]
    untagged_ports: tuple[str, ...]

    @property
    def tagged_ports(self) -> tuple[str, ...]:
        return tuple(p for p in self.access_ports if p not in self.untagged_ports)


@dataclass(frozen=True)
class Inventory:
    nodes: tuple[Node, ...]
    raw: dict[str, Any] = field(compare=False, repr=False)

    @property
    def leaves(self) -> tuple[Node, ...]:
        return tuple(n for n in self.nodes if n.role != "spine")

    def node(self, name: str) -> Node | None:
        return next((n for n in self.nodes if n.name == name), None)

    @classmethod
    def from_dict(cls, raw: dict[str, Any]) -> Inventory:
        nodes = []
        for n in raw.get("nodes") or []:
            access = tuple(str(p) for p in n.get("accessPorts") or [])
            nodes.append(Node(str(n["name"]), str(n.get("role") or "leaf"), access,
                              tuple(str(p) for p in n.get("untaggedAccessPorts") or [])))
        return cls(tuple(nodes), raw)


def load_inventory(directory: Path) -> Inventory:
    path = Path(directory) / INVENTORY_FILE
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(raw, dict):
            raise ValueError("not an object")
        return Inventory.from_dict(raw)
    except (OSError, ValueError, KeyError, TypeError) as exc:
        raise MapperFailure(f"site inventory unreadable at {path}: {exc}") from None


def load_qualification(directory: Path) -> dict[str, str]:
    """The qualification record as ``{key: state}``: one flat key per mounted file
    (``mac-vrf``, ``acl.egress`` …), completed from ``qualification.json`` for any key the flat
    files do not carry. An absent record is empty — nothing is shown as qualified."""
    record: dict[str, str] = {}
    directory = Path(directory)
    try:
        entries = sorted(directory.iterdir())
    except OSError:
        return record
    for entry in entries:
        if entry.name.startswith(".") or entry.name == "qualification.json" or not entry.is_file():
            continue
        try:
            record[entry.name] = entry.read_text(encoding="utf-8").strip()
        except OSError:
            continue
    try:
        doc = json.loads((directory / "qualification.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return record
    for construct, body in (doc.get("constructs") or {}).items():
        if isinstance(body, dict):
            record.setdefault(construct, QUALIFIED if body.get("qualified") else "unqualified")
            for prop, pbody in (body.get("properties") or {}).items():
                if isinstance(pbody, dict):
                    record.setdefault(f"{construct}.{prop}",
                                      QUALIFIED if pbody.get("qualified") else "unqualified")
    return record


# --------------------------------------------------------------------------------------------------
# model output
# --------------------------------------------------------------------------------------------------


def content_of(response: Any) -> str:
    """The assistant text of a model response: a LiteLLM ``ModelResponse``, its dict form, or a
    plain string (test doubles)."""
    if isinstance(response, str):
        return response
    if isinstance(response, dict):
        return str(response["choices"][0]["message"]["content"] or "")
    return str(response.choices[0].message.content or "")


def extract_json(text: str) -> dict[str, Any]:
    """The first JSON object in ``text`` (code fences tolerated). Raises ValueError."""
    start = text.find("{")
    if start < 0:
        raise ValueError("the answer holds no JSON object")
    try:
        value, _ = json.JSONDecoder().raw_decode(text[start:])
    except json.JSONDecodeError as exc:
        raise ValueError(f"the answer's JSON does not parse: {exc.msg}") from None
    if not isinstance(value, dict):
        raise ValueError("the answer's JSON is not an object")
    return value


def _failed_payload(answer: str) -> Any:
    """The model answer that failed validation: its JSON object when one parses, else the text."""
    try:
        return extract_json(answer)
    except ValueError:
        return answer


def validation_summary(exc: ValidationError) -> str:
    parts = []
    for err in exc.errors()[:5]:
        where = ".".join(str(p) for p in err.get("loc", ())) or "interpretation"
        parts.append(f"{where}: {err.get('msg')}")
    more = f" (+{len(exc.errors()) - 5} more)" if len(exc.errors()) > 5 else ""
    return "; ".join(parts) + more


def validate_model_output(raw_text: str, service_id: str) -> Interpretation:
    """Extract and validate strictly; ``service_id`` is the platform's, set before validation so
    whatever the model wrote there is neither used nor judged. Raises ValueError."""
    data = extract_json(raw_text)
    data["service_id"] = service_id
    acl_mod.prepare(data)  # the family folded; what the schema cannot carry refused by name
    try:
        return Interpretation.parse(data)
    except ValidationError as exc:
        raise ValueError(validation_summary(exc)) from None


# --------------------------------------------------------------------------------------------------
# the deterministic review
# --------------------------------------------------------------------------------------------------


def canonical_port(port: str) -> str:
    folded = port.strip().lower()
    m = _PORT.match(folded)
    return f"ethernet-{m.group(1)}/{m.group(2)}" if m else folded


def _names(items: Iterable[str]) -> str:
    items = list(items)
    return ", ".join(items) if items else "none"


def _and(items: list[str]) -> str:
    return items[0] if len(items) == 1 else ", ".join(items[:-1]) + " and " + items[-1]


def band_refusal(path: str, vlan: int, construct: str) -> str | None:
    """The naming-band cause for a VLAN the operator named, or None when it is in 100-999."""
    lo, hi = NAMING_BAND
    if lo <= vlan <= hi:
        return None
    alternative = ("or name none for the untagged subinterface" if construct == "ip-vrf"
                   else "or name none and one is allocated")
    if ALLOCATION_BAND[0] <= vlan <= ALLOCATION_BAND[1]:
        return (f"{path}: {vlan} lies in the allocation band {ALLOCATION}, which is the "
                f"allocation authority's to hand out; name a VLAN from the naming band {NAMING}, "
                f"{alternative}")
    if vlan < lo:
        where = f"{vlan} is below the naming band {NAMING}"
    elif vlan <= 4094:
        where = f"{vlan} lies above the allocation band, outside the VLAN space {SPACE} " \
                "this platform uses"
    elif vlan == 4095:
        where = f"{vlan} is the reserved 802.1Q VLAN, outside the VLAN space {SPACE} " \
                "this platform uses"
    else:
        where = (f"{vlan} is not an 802.1Q VLAN at all (1\u20134094), let alone one of the "
                 f"VLAN space {SPACE} this platform uses")
    return (f"{path}: {where}; name a VLAN from the naming band {NAMING} — the allocation band "
            f"{ALLOCATION} is the allocation authority's to hand out — {alternative}")


def _address(value: str) -> ipaddress.IPv4Address | ipaddress.IPv6Address | None:
    try:
        return ipaddress.ip_address(value)
    except ValueError:
        return None


def written_addresses(text: str) -> set[ipaddress.IPv4Address | ipaddress.IPv6Address]:
    """Every IPv4/IPv6 address the operator's text holds, by value (a prefix length, a trailing
    full stop and the case or compression of an IPv6 address do not matter)."""
    found = set()
    for token in _ADDRESS_TOKEN.findall(text):
        for candidate in (token, token.rstrip("."), token.rstrip(".:")):
            address = _address(candidate)
            if address is not None:
                found.add(address)
                break
    return found


def declared_gateway(gateway: dict[str, Any] | None, text: str,
                     families: Iterable[str]) -> dict[str, Any] | None:
    """The gateway with only the address families the operator wrote (FR-032: an unrequested
    family is never added). A family whose address is absent from ``text`` is set to null; when
    none remains, the gateway stays (every family null — a missing field) if the operator asked
    for one, and is removed if the request never mentions a gateway."""
    if gateway is None:
        return None
    written = written_addresses(text)
    kept = dict(gateway)
    for fam in families:
        value = gateway.get(fam)
        if not value:
            continue
        part = str(value).split("/", 1)[0].strip()
        address = _address(part)
        said = (address in written) if address is not None else (
            part.lower() != PLACEHOLDER and bool(part) and part.lower() in text.lower())
        if not said:
            kept[fam] = None
    if any(kept.get(fam) for fam in families):
        return kept
    return kept if _GATEWAY_WORDS.search(text) else None


def _qualification_needs(interp: Interpretation, construct: str, catalogue: Catalogue,
                         gateway: dict[str, Any] | None) -> list[tuple[str, str, str]]:
    """``(path, what, record key)`` for the construct and each gated property the request uses;
    the gateway's per-family keys are the catalogue's (``mac-vrf.anycast-gateway-<family>``)."""
    needs = [("service_type", f"the {construct} construct", construct)]
    if gateway is not None:
        for fam, key in catalogue.gateway_families().items():
            if gateway.get(fam):
                needs.append((f"anycast_gateway.{fam}", f"the {fam.upper()[:2]}{fam[2:]} anycast "
                              "gateway", key))
    if construct == "ip-vrf":
        for fam, prefixes in (("ipv4", interp.ipv4_prefixes), ("ipv6", interp.ipv6_prefixes)):
            if prefixes:
                needs.append((f"{fam}_prefixes", f"{fam.upper()[:2]}{fam[2:]} EVPN IP-prefix "
                              "routes", f"ip-vrf.evpn-type5-{fam}"))
    if interp.acl is not None:
        if construct != "acl":
            needs.append(("acl", "the acl construct", "acl"))
        if interp.acl.stage == "egress":
            needs.append(("acl.stage", "an egress access-list binding", "acl.egress"))
        else:
            needs.append(("acl.type", f"an ingress {interp.acl.type} access list",
                          f"acl.ingress-{interp.acl.type}"))
    return needs


def _one_construct(entry: str, catalogue: Catalogue) -> str | None:
    """Re-render a model's "one construct per request" cause canonically, naming the constructs
    it mentions in the order it mentions them."""
    if not entry.lower().startswith("request") or "one construct" not in entry.lower():
        return None
    found: list[str] = []
    words = [w for w in re.split(r"[\s,;:.—()'\"]+", entry) if w]
    i = 0
    while i < len(words):
        pair = catalogue.fold(words[i] + words[i + 1]) if i + 1 < len(words) else None
        folded = pair or catalogue.fold(words[i])
        i += 2 if pair else 1
        if folded and folded[0] not in found:
            found.append(folded[0])
    if len(found) < 2:
        return None
    return f"request: one construct per request — you asked for {_and(found)}; send one"


def review(interp: Interpretation, *, text: str, inventory: Inventory,
           qualification: dict[str, str], catalogue: Catalogue) -> Interpretation:
    """The deterministic half of the stage: every platform rule, applied in code. Returns a new
    Interpretation; the causes it finds are all collected (all-or-nothing)."""
    data = interp.model_dump(mode="json", exclude_unset=True)
    unsupported: list[str] = []
    # an access-list rule's match fields are optional — unstated means "match anything" — so the
    # model listing one as missing is never a question for the operator (T114 live finding)
    missing: list[str] = [m for m in interp.missing_fields
                          if not acl_mod.OPTIONAL_MATCH_PATH.match(m)]
    for entry in interp.unsupported_properties:
        unsupported.append(_one_construct(entry, catalogue) or entry)

    # the construct and its recorded arrival vocabulary (construct-vocabulary.md §2)
    construct = interp.service_type
    if interp.source_service_type is not None:
        construct = ALIAS_CONSTRUCT[interp.source_service_type]
        data["service_type"] = construct

    # unsupported claims the catalogue names, found in the operator's own words
    for claim in catalogue.unsupported:
        if claim.found_in(text) and not any(claim.name.lower() in u.lower() for u in unsupported):
            unsupported.append(f"{claim.name}: not supported — this platform provisions the "
                               "constructs vlan, mac-vrf, ip-vrf and acl, and none carries it")

    if data.get("tenant") == PLACEHOLDER and "tenant" not in missing:
        missing.append("tenant")

    # endpoints: inventory, naming band, tagging mode
    endpoints = data["endpoints"]
    named_vlans: list[int] = []
    for i, ep in enumerate(endpoints):
        node_path, port_path, vlan_path = (f"endpoints[{i}].site_or_node",
                                           f"endpoints[{i}].attachment", f"endpoints[{i}].vlan")
        node_name = ep["site_or_node"].strip().lower()
        port_name = canonical_port(ep["attachment"])
        vlan = ep.get("vlan")
        node_known = node_name != PLACEHOLDER and node_path not in missing
        port_known = port_name != PLACEHOLDER and port_path not in missing
        if not node_known and node_path not in missing:
            missing.append(node_path)
        if not port_known and port_path not in missing:
            missing.append(port_path)
        node = inventory.node(node_name) if node_known else None
        if node_known:
            ep["site_or_node"] = node_name
            leaves = _names(n.name for n in inventory.leaves)
            if node is None:
                unsupported.append(f"{node_path}: '{ep['site_or_node']}' is not a node of this "
                                   f"site; its attachment nodes are {leaves}")
            elif node.role == "spine":
                unsupported.append(f"{node_path}: {node.name} is a spine, and spines are not "
                                   f"attachment points; this site's attachment nodes are {leaves}")
                node = None
        if port_known:
            ep["attachment"] = port_name
            if node is not None and port_name not in node.access_ports:
                unsupported.append(f"{port_path}: {node.name} has no access port '{port_name}'; "
                                   f"its access ports are {_names(node.access_ports)}")
                node = None
        if construct == "acl":
            # a reference to another service's subinterface (AD-47): exempt from the naming
            # band, held to the platform's VLAN space
            cause = acl_mod.reference_vlan_refusal(vlan_path, vlan) if vlan is not None else None
            if cause:
                unsupported.append(cause)
            continue
        if vlan is not None:
            named_vlans.append(vlan)
            cause = band_refusal(vlan_path, vlan, construct)
            if cause:
                unsupported.append(cause)
        if node is None or not port_known:
            continue
        tagged = vlan is not None or construct in ("vlan", "mac-vrf")
        untagged_port = port_name in node.untagged_ports
        if tagged and untagged_port:
            unsupported.append(
                f"endpoints[{i}]: {node.name} {port_name} is declared untagged, and a "
                f"{construct} attachment{' naming a VLAN' if vlan is not None else ''} is tagged; "
                f"the ports declared tagged on {node.name} are {_names(node.tagged_ports)}")
        elif not tagged and not untagged_port:
            unsupported.append(
                f"endpoints[{i}]: {node.name} {port_name} is declared tagged, and an ip-vrf "
                f"endpoint naming no VLAN asks for the untagged subinterface; the ports declared "
                f"untagged on {node.name} are {_names(node.untagged_ports)} — or name a VLAN from "
                f"the naming band {NAMING}")

    # one bridge domain is one broadcast domain
    if construct in ("vlan", "mac-vrf") and len(set(named_vlans)) > 1:
        distinct = sorted(set(named_vlans))
        unsupported.append(f"endpoints[].vlan: the request names VLANs "
                           f"{_and([str(v) for v in distinct])}; a {construct} is one broadcast "
                           "domain, so every endpoint shares one VLAN")

    # the gateway, a property of mac-vrf: only the families the operator declared (FR-032)
    gateway = declared_gateway(data.get("anycast_gateway"), text,
                               catalogue.gateway_families())
    if gateway is None:
        data.pop("anycast_gateway", None)
    else:
        data["anycast_gateway"] = gateway

    # per-construct completeness (construct-vocabulary.md §3)
    if construct == "mac-vrf":
        if gateway is not None and not (gateway.get("ipv4") or gateway.get("ipv6")):
            missing.append("anycast_gateway.ipv4 or anycast_gateway.ipv6")
        if len(endpoints) < 2 and gateway is None:
            missing.append(f"endpoints[{len(endpoints)}]")
    if construct == "ip-vrf" and not (interp.ipv4_prefixes or interp.ipv6_prefixes):
        missing.append("ipv4_prefixes or ipv6_prefixes")

    # the access list (T111; FR-035 to FR-041)
    if interp.acl is not None:
        family_refused = any(c.startswith("acl.type:") for c in unsupported)
        data["acl"], acl_causes = acl_mod.review_acl(interp.acl, family_refused=family_refused)
        unsupported.extend(acl_causes)

    # the qualification record (FR-097)
    for path, what, key in _qualification_needs(interp, construct, catalogue, gateway):
        state = qualification.get(key)
        if state != QUALIFIED:
            said = f"records it as {state!r}" if state else "does not record it"
            unsupported.append(f"{path}: {what} is not shown as qualified in the fabric "
                               f"qualification record ({key}), which {said}; it is refused before "
                               "anything is claimed")

    data["unsupported_properties"] = list(dict.fromkeys(unsupported))
    data["missing_fields"] = [] if unsupported else list(dict.fromkeys(missing))
    return Interpretation.parse(data)


def summary(interp: Interpretation) -> str:
    wire = json.dumps(interp.to_wire(), separators=(",", ":"), sort_keys=True)
    if interp.unsupported_properties:
        head = "I cannot map this request:\n" + "\n".join(
            f"- {c}" for c in interp.unsupported_properties)
    elif interp.missing_fields:
        head = "Before I can map this request I need: " + ", ".join(interp.missing_fields) + "."
    else:
        eps = "; ".join(
            f"{e.site_or_node} {e.attachment}" + (f" vlan {e.vlan}" if e.vlan is not None else
                                                   (" untagged" if interp.service_type == "ip-vrf"
                                                    else ""))
            for e in interp.endpoints)
        head = (f"Interpretation {interp.service_id}: a {interp.service_type} for tenant "
                f"{interp.tenant} on {eps}.")
    return f"{redact(head)}\n<!-- {MARKER}: {wire} -->"


# --------------------------------------------------------------------------------------------------
# the stage
# --------------------------------------------------------------------------------------------------


class Mapper:
    """The mapper stage over its mounted inputs and a model client (built on first use)."""

    def __init__(self, settings: Settings, *, llm: ModelClient | None = None,
                 llm_factory: Callable[[], ModelClient] | None = None,
                 catalogue_dir: Path | None = None) -> None:
        self.settings = settings
        self._llm = llm
        self._llm_factory = llm_factory
        env_dir = (settings.extra or {}).get("MAPPER_CATALOGUE_DIR", "").strip()
        self.catalogue_dir = catalogue_dir or (Path(env_dir) if env_dir
                                               else catalogue_mod.DEFAULT_CATALOGUE_DIR)
        self.model_calls = 0

    def llm(self) -> ModelClient:
        if self._llm is None:
            if self._llm_factory is not None:
                self._llm = self._llm_factory()
            else:
                from common.llm import LLMClient

                self._llm = LLMClient(self.settings.llm_provider_dir)
        return self._llm

    async def _complete(self, messages: list[dict[str, Any]]) -> str:
        self.model_calls += 1
        try:
            response = await asyncio.to_thread(self.llm().complete, messages)
        except Exception as exc:
            raise MapperFailure(f"model call failed: {redact(str(exc)) or type(exc).__name__}"
                                ) from None
        try:
            return content_of(response)
        except (KeyError, IndexError, AttributeError, TypeError) as exc:
            raise MapperFailure(f"model answer unreadable: {type(exc).__name__}") from None

    async def interpret(self, text: str) -> Interpretation:
        catalogue = catalogue_mod.load(self.catalogue_dir)
        inventory = load_inventory(self.settings.site_inventory_dir)
        qualification = load_qualification(self.settings.fabric_qualification_dir)
        prompt = prompts.build(catalogue, inventory.raw, text)
        if prompt.quarantined:
            log.info("mapper: %d instruction-like segment(s) quarantined from the request",
                     len(prompt.quarantined))
        messages = prompts.messages(prompt)
        service_id = generate_service_id()
        answer = await self._complete(messages)
        try:
            interp = validate_model_output(answer, service_id)
        except ValueError as first:
            log.warning("mapper: schema-invalid model output, one retry: %s", first)
            retry = [*messages, {"role": "assistant", "content": answer},
                     prompts.retry_message(str(first))]
            answer = await self._complete(retry)
            try:
                interp = validate_model_output(answer, service_id)
            except ValueError as second:
                reason = f"schema-invalid model output (after one retry): {second}"
                # The trace keeps the interpretation that failed validation (T135).
                tracing.mark_worker_failure("mapper", reason, payload=_failed_payload(answer),
                                            errors=str(second))
                raise MapperFailure(reason) from None
        return review(interp, text=text, inventory=inventory, qualification=qualification,
                      catalogue=catalogue)

    async def handle(self, request: StageMessage) -> Message:
        payload = request.data if isinstance(request.data, dict) else {}
        text = payload.get("text", request.text if not payload else None)
        operation = payload.get("operation", request.operation or "create")
        if operation != "create":
            return reply_failed(f"operation {operation!r} is not the mapper's: it maps create "
                                "requests only")
        if not isinstance(text, str) or not text.strip():
            return reply_failed("payload.text: the request text is required")
        try:
            interp = await self.interpret(text)
        except MapperFailure as exc:
            log.warning("mapper: %s", exc)
            return reply_failed(str(exc))
        except catalogue_mod.CatalogueError as exc:
            return reply_failed(str(exc))
        outcome = ("refused" if interp.unsupported_properties else
                   "clarification" if interp.missing_fields else "interpreted")
        if interp.unsupported_properties:
            # A refusal at interpretation (the band check, an unqualified property): the
            # interpretation that was refused goes on the trace with its causes (T135).
            causes = list(interp.unsupported_properties)
            tracing.mark_worker_failure("mapper", "; ".join(causes), payload=interp.to_wire(),
                                        errors=causes)
        log.info("mapper: %s service %s (%s)", outcome, interp.service_id, interp.service_type)
        return reply_ok(summary(interp), interp.to_wire())


__all__ = ["ALLOCATION_BAND", "CONSTRUCTS", "NAMING_BAND", "Inventory", "Mapper",
           "MapperFailure", "band_refusal", "canonical_port", "content_of", "declared_gateway",
           "extract_json", "generate_service_id", "load_inventory", "load_qualification",
           "review", "summary", "validate_model_output", "written_addresses"]
