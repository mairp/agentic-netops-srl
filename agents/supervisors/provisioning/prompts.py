"""``GET /suggested-prompts`` (T085; FR-084, FR-097, R-30, contracts/supervisor-http.md).

Serves the four constructs and nothing else — six shapes: a vlan, a mac-vrf across two leaves, an
ip-vrf, the gateway composition, a standalone acl on an attachment, and an acl attached to a
service in the same request, authored in ``suggested_prompts.json`` beside this module (T139). A
prompt is served only when every (node, port) it names resolves in the site inventory the
provisioning script writes (``SITE_INVENTORY_DIR/inventory.json``, the ``Fabric`` inventory:
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


SUGGESTED_PROMPTS_FILE = Path(__file__).resolve().parent / "suggested_prompts.json"
CONSTRUCTS = ("vlan", "mac-vrf", "ip-vrf", "acl")


def load_suggestions(path: Path | None = None) -> list[dict[str, Any]]:
    """The authored suggestion set (``suggested_prompts.json``, T139): six shapes, each with its
    construct, the qualification keys it uses and the (node, port) endpoints its text names."""
    document = json.loads(Path(path or SUGGESTED_PROMPTS_FILE).read_text(encoding="utf-8"))
    return list(document["prompts"])


def resolves(entry: dict[str, Any], leaves: list[Leaf]) -> bool:
    """Every endpoint of ``entry`` is a leaf's access port in the site inventory, and appears in
    the prompt text in the device's own naming."""
    ports = {leaf.name: set(leaf.ports) for leaf in leaves}
    text = entry.get("prompt", "")
    endpoints = entry.get("endpoints") or []
    return bool(endpoints) and all(
        e.get("port") in ports.get(e.get("node"), set()) and f"{e['node']} {e['port']}" in text
        for e in endpoints
    )


def suggested_prompts(inventory_dir: Path, qualification_dir: Path) -> dict[str, Any]:
    leaves = load_leaves(inventory_dir)
    if not leaves:
        return {
            "prompts": [],
            "note": (
                "no site inventory with leaf access ports at "
                f"{Path(inventory_dir) / INVENTORY_FILE}; "
                "prompts are only offered on the site's real nodes and ports"
            ),
        }
    prompts = [
        {"shape": e["shape"], "construct": e["construct"], "prompt": e["prompt"]}
        for e in load_suggestions()
        if e.get("construct") in CONSTRUCTS
        and resolves(e, leaves)
        and all(qualified(qualification_dir, k) for k in e.get("requires", []))
    ]
    return {"prompts": prompts}


__all__ = [
    "CONSTRUCTS",
    "PACKAGED_PROMPTS",
    "PROMPTS_ENV",
    "SUGGESTED_PROMPTS_FILE",
    "load_leaves",
    "load_prompt",
    "load_suggestions",
    "prompt_names",
    "prompts_dir",
    "qualified",
    "render",
    "resolves",
    "suggested_prompts",
]
