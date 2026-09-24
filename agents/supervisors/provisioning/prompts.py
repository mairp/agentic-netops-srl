"""``GET /suggested-prompts`` (T085; FR-084, FR-097, R-30, contracts/supervisor-http.md).

Serves the four constructs and nothing else — six shapes: a vlan, a mac-vrf across two leaves, an
ip-vrf, the gateway composition, a standalone acl on an attachment, and an acl attached to a
service in the same request. Every node and port comes from the site inventory the provisioning
script writes (``SITE_INVENTORY_DIR/inventory.json``, the ``Fabric`` inventory:
``{"nodes": [{"name": "leaf01", "role": "leaf", "accessPorts": ["ethernet-1/1", …]}, …]}``),
in the device's own naming; nothing is invented. A prompt is offered only when the qualification
record (``FABRIC_QUALIFICATION_DIR``, one file per flat key, ``qualified``/``unqualified``) shows
its construct and every gated property it uses as qualified — an absent key is unqualified.

It also loads the supervisor's own prompt texts (T102; FR-026): the informational system prompt and
the confirmation, decline and refusal wording, one ``prompts/<name>.md`` file each, written in the
construct vocabulary only. They are read from ``SUPERVISOR_PROMPTS_DIR`` — the read-only mount of
ConfigMap ``supervisor-prompts``, whose data is byte-equal to the packaged files — and fall back,
file by file, to the defaults packaged beside this module. Placeholders are ``{name}`` fields,
filled by :func:`render`; a missing field is an error, never a silently blank phrase.
"""

from __future__ import annotations

import json
import os
from dataclasses import dataclass
from pathlib import Path
from typing import Any

INVENTORY_FILE = "inventory.json"
PROMPTS_ENV = "SUPERVISOR_PROMPTS_DIR"
PACKAGED_PROMPTS = Path(__file__).resolve().parent / "prompts"


def prompts_dir(env: dict[str, str] | None = None) -> Path:
    """The configured prompt directory (``SUPERVISOR_PROMPTS_DIR``), else the packaged one."""
    value = (os.environ if env is None else env).get(PROMPTS_ENV, "").strip()
    return Path(value) if value else PACKAGED_PROMPTS


def prompt_names() -> list[str]:
    """The packaged prompt names (file stems), sorted."""
    return sorted(p.stem for p in PACKAGED_PROMPTS.glob("*.md"))


def load_prompt(name: str, directory: Path | None = None) -> str:
    """The text of prompt ``name`` (without its trailing newline): from the configured directory
    when it holds the file, otherwise the packaged default. Read on every use, so an updated
    ConfigMap needs no restart."""
    for base in (directory or prompts_dir(), PACKAGED_PROMPTS):
        try:
            return (Path(base) / f"{name}.md").read_text(encoding="utf-8").rstrip("\n")
        except OSError:
            continue
    raise FileNotFoundError(f"supervisor prompt {name!r} is neither configured nor packaged")


def render(name: str, **fields: Any) -> str:
    """Prompt ``name`` with its ``{field}`` placeholders filled from ``fields``."""
    return load_prompt(name).format_map(fields)


@dataclass(frozen=True)
class Leaf:
    name: str
    ports: tuple[str, ...]


def load_leaves(inventory_dir: Path) -> list[Leaf] | None:
    path = Path(inventory_dir) / INVENTORY_FILE
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    leaves = []
    for node in document.get("nodes", []) if isinstance(document, dict) else []:
        if not isinstance(node, dict) or node.get("role") != "leaf":
            continue
        ports = tuple(p for p in node.get("accessPorts", []) or [] if isinstance(p, str))
        if isinstance(node.get("name"), str) and ports:
            leaves.append(Leaf(node["name"], ports))
    return sorted(leaves, key=lambda leaf: leaf.name)


def qualified(qualification_dir: Path, key: str) -> bool:
    try:
        return (Path(qualification_dir) / key).read_text(encoding="utf-8").strip() == "qualified"
    except OSError:
        return False


def _port(leaf: Leaf, index: int) -> str:
    return leaf.ports[min(index, len(leaf.ports) - 1)]


def suggested_prompts(inventory_dir: Path, qualification_dir: Path) -> dict[str, Any]:
    leaves = load_leaves(inventory_dir)
    if not leaves:
        return {"prompts": [], "note": (
            f"no site inventory with leaf access ports at {Path(inventory_dir) / INVENTORY_FILE}; "
            "prompts are only offered on the site's real nodes and ports")}
    a = leaves[0]
    b = leaves[1] if len(leaves) > 1 else None
    candidates: list[tuple[str, str, list[str], str]] = [
        ("vlan", "vlan", ["vlan"],
         f"Create vlan 120 on {a.name} {_port(a, 1)} for tenant acme"),
    ]
    if b is not None:
        candidates += [
            ("mac-vrf", "mac-vrf", ["mac-vrf"],
             f"Extend vlan 100 as a mac-vrf across {a.name} {_port(a, 0)} and {b.name} "
             f"{_port(b, 0)} for tenant blue"),
            ("gateway", "mac-vrf", ["mac-vrf", "mac-vrf.anycast-gateway-ipv4"],
             f"Extend vlan 130 as a mac-vrf across {a.name} {_port(a, 2)} and {b.name} "
             f"{_port(b, 2)} with an anycast gateway 10.30.0.1/24 for tenant blue"),
        ]
    candidates += [
        ("ip-vrf", "ip-vrf", ["ip-vrf", "ip-vrf.evpn-type5-ipv4"],
         f"Create an ip-vrf for tenant initech carrying 10.50.0.0/24 at {a.name} "
         f"{_port(a, 3)} vlan 200"),
        ("acl", "acl", ["acl", "acl.ingress-ipv4"],
         f"Add an ingress ipv4 acl on {a.name} {_port(a, 1)} vlan 120 for tenant acme that "
         "permits tcp to port 443 and denies everything else"),
        ("acl-on-service", "vlan", ["vlan", "acl", "acl.ingress-ipv4"],
         f"Create vlan 140 on {a.name} {_port(a, 3)} for tenant acme with an ingress ipv4 acl "
         "that denies udp to port 53"),
    ]
    prompts = [{"shape": shape, "construct": construct, "prompt": text}
               for shape, construct, keys, text in candidates
               if all(qualified(qualification_dir, k) for k in keys)]
    return {"prompts": prompts}


__all__ = ["PACKAGED_PROMPTS", "PROMPTS_ENV", "load_leaves", "load_prompt", "prompt_names",
           "prompts_dir", "qualified", "render", "suggested_prompts"]
