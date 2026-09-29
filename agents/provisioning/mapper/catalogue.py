"""The mapper's construct catalogue (T098; contracts/construct-vocabulary.md,
kubernetes-objects.md).

The catalogue is the vocabulary the mapper's prompt is built from — the four constructs, their
variables and examples, the input-only aliases, and the unsupported claims named by the refusal
of construct-vocabulary.md §5. It is configuration, not code: the ``mapper-catalogue`` ConfigMap
(``deploy/agents/mapper-catalogue.yaml``, key ``catalogue.json``) is mounted read-only at
``MAPPER_CATALOGUE_DIR`` and read from there; the packaged ``catalogue.json`` beside this module is
the default when nothing is mounted, and a unit test asserts it equals the ConfigMap's content byte
for byte, so the two can never drift.

The catalogue never widens the vocabulary: a construct outside the four is refused on load.

The anycast gateway is a **property** of ``mac-vrf`` (T117; construct-vocabulary.md §3,
kuid-claim-profiles.md §2-§4, data-model.md §8/§10; FR-032, FR-097, CR-002, CR-010), described by
the ``mac-vrf`` entry's ``properties.anycast_gateway`` block — never a fifth construct: it makes
the ``mac-vrf`` route through a routed instance with an L3VNI; only the declared address families
are configured (an unrequested family is never added); no gateway means no routed instance and no
L3 identifier. Each family carries its qualification-record key
(``mac-vrf.anycast-gateway-ipv4|ipv6``), read through :meth:`Catalogue.gateway_families`; a
catalogue whose gateway block is missing, sits on another construct, or names another family or
key is refused on load.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any

CATALOGUE_KEY = "catalogue.json"
DEFAULT_CATALOGUE_DIR = Path("/etc/agentic-netops/mapper-catalogue")
PACKAGED = Path(__file__).resolve().parent / CATALOGUE_KEY
CONSTRUCTS = ("vlan", "mac-vrf", "ip-vrf", "acl")
SOURCE_TYPES = ("VPLS", "VPWS", "L3VPN", "L2L3-IRB")  # migration alias (FR-044)
GATEWAY_PROPERTY = "anycast_gateway"
GATEWAY_CONSTRUCT = "mac-vrf"
GATEWAY_FAMILIES = ("ipv4", "ipv6")


class CatalogueError(ValueError):
    """The catalogue cannot be read or widens the vocabulary."""


@dataclass(frozen=True)
class UnsupportedClaim:
    name: str
    patterns: tuple[re.Pattern[str], ...]

    def found_in(self, text: str) -> bool:
        return any(p.search(text) for p in self.patterns)


@dataclass(frozen=True)
class Catalogue:
    raw: dict[str, Any]
    source: str
    constructs: tuple[dict[str, Any], ...]
    aliases: dict[str, dict[str, str]]
    unsupported: tuple[UnsupportedClaim, ...]

    def construct(self, name: str) -> dict[str, Any]:
        for c in self.constructs:
            if c["name"] == name:
                return c
        raise KeyError(name)

    def gateway(self) -> dict[str, Any]:
        """The gateway property block of the ``mac-vrf`` entry (validated on load)."""
        return self.construct(GATEWAY_CONSTRUCT)["properties"][GATEWAY_PROPERTY]

    def gateway_families(self) -> dict[str, str]:
        """``{family: qualification-record key}`` of the gateway, in the fixed family order."""
        families = self.gateway()["families"]
        return {fam: str(families[fam]) for fam in GATEWAY_FAMILIES}

    def gateway_qualification_key(self, family: str) -> str:
        """The qualification-record key of one gateway address family. Raises KeyError."""
        return self.gateway_families()[family]

    def fold(self, name: str) -> tuple[str, str | None] | None:
        """Name resolution of construct-vocabulary.md §2: ``(construct, source type)``."""
        key = re.sub(r"[-_ .+]", "", name.lower())
        for c in CONSTRUCTS:
            if key == c.replace("-", ""):
                return c, None
        alias = self.aliases.get(key)
        if alias is None:
            return None
        return alias["construct"], alias.get("source_service_type")


def parse(text: str, *, source: str) -> Catalogue:
    try:
        raw = json.loads(text)
    except json.JSONDecodeError as exc:
        raise CatalogueError(f"mapper catalogue {source} is not JSON: {exc.msg}") from None
    if not isinstance(raw, dict):
        raise CatalogueError(f"mapper catalogue {source} is not an object")
    constructs = raw.get("constructs")
    if not isinstance(constructs, list) or [c.get("name") for c in constructs
                                            if isinstance(c, dict)] != list(CONSTRUCTS):
        raise CatalogueError(
            f"mapper catalogue {source} must list exactly the four constructs "
            f"{', '.join(CONSTRUCTS)}, in that order")
    _check_gateway(constructs, source)
    aliases = raw.get("aliases") or {}
    if not isinstance(aliases, dict):
        raise CatalogueError(f"mapper catalogue {source}: aliases is not an object")
    for key, alias in aliases.items():
        if not isinstance(alias, dict) or alias.get("construct") not in CONSTRUCTS or (
                alias.get("source_service_type") not in (None, *SOURCE_TYPES)):
            raise CatalogueError(f"mapper catalogue {source}: alias {key!r} folds to no construct")
    unsupported: list[UnsupportedClaim] = []
    for entry in raw.get("unsupported_claims") or []:
        try:
            unsupported.append(UnsupportedClaim(
                str(entry["name"]), tuple(re.compile(p, re.IGNORECASE) for p in entry["patterns"])))
        except (KeyError, TypeError, re.error) as exc:
            raise CatalogueError(
                f"mapper catalogue {source}: bad unsupported claim {entry!r}: {exc}") from None
    return Catalogue(raw, source, tuple(constructs), dict(aliases), tuple(unsupported))


def _check_gateway(constructs: list[Any], source: str) -> None:
    """The gateway is a property of ``mac-vrf`` and of nothing else, one key per family."""
    for c in constructs:
        props = c.get("properties") or {}
        if not isinstance(props, dict):
            raise CatalogueError(f"mapper catalogue {source}: {c['name']}.properties is not an "
                                 "object")
        if GATEWAY_PROPERTY in props and c["name"] != GATEWAY_CONSTRUCT:
            raise CatalogueError(f"mapper catalogue {source}: {GATEWAY_PROPERTY} is a property of "
                                 f"{GATEWAY_CONSTRUCT} only, not of {c['name']}")
    macvrf = next(c for c in constructs if c["name"] == GATEWAY_CONSTRUCT)
    gateway = (macvrf.get("properties") or {}).get(GATEWAY_PROPERTY)
    families = gateway.get("families") if isinstance(gateway, dict) else None
    expected = {fam: f"{GATEWAY_CONSTRUCT}.anycast-gateway-{fam}" for fam in GATEWAY_FAMILIES}
    if not isinstance(gateway, dict) or gateway.get("belongs_to") != GATEWAY_CONSTRUCT or (
            families != expected):
        raise CatalogueError(
            f"mapper catalogue {source}: {GATEWAY_CONSTRUCT}.properties.{GATEWAY_PROPERTY} must "
            f"belong to {GATEWAY_CONSTRUCT} and name the families "
            f"{', '.join(f'{k} ({v})' for k, v in expected.items())}")


def load(directory: Path | None = None) -> Catalogue:
    """The mounted catalogue (``<directory>/catalogue.json``) when present, else the packaged
    default. A mounted catalogue that cannot be parsed is an error, never a silent fallback."""
    if directory is not None:
        mounted = Path(directory) / CATALOGUE_KEY
        try:
            text = mounted.read_text(encoding="utf-8")
        except (FileNotFoundError, NotADirectoryError):
            text = None
        if text is not None:
            return parse(text, source=str(mounted))
    return parse(PACKAGED.read_text(encoding="utf-8"), source=str(PACKAGED))


__all__ = ["CATALOGUE_KEY", "CONSTRUCTS", "DEFAULT_CATALOGUE_DIR", "GATEWAY_CONSTRUCT",
           "GATEWAY_FAMILIES", "GATEWAY_PROPERTY", "PACKAGED", "Catalogue", "CatalogueError",
           "UnsupportedClaim", "load", "parse"]
