"""The deployer's binding pre-flight (T112; contracts/kubernetes-objects.md §"Submission
contract" step 1, acl-render-contract.md §6, construct-vocabulary.md §5; FR-034, FR-043, FR-062,
FR-109; AD-20, AD-26, AD-33, AD-68).

Before anything is created, the assignment is compared with every ``Network`` in
``agentic-netops-intent`` — **the only namespace this identity may read a ``Network`` in**
(FR-075) — and refused, naming the incumbent ``Network <namespace>/<name>``, for:

* a **second owner** of a (node, port, VLAN) subinterface;
* a **conflicting tagging mode** on a (node, port): tagging is a property of the port, one mode
  per port;
* an **access-list binding** on an exclusivity key another ``Network`` already holds —
  ``(node, port, subinterface index, direction, address family)``. IPv4 and IPv6 lists on one
  subinterface, or lists on different subinterfaces of one port, do not conflict;
* an attachment in the mode **other than the site inventory declares** for its port
  (``untaggedAccessPorts``, AD-68), listing the ports declared in the mode asked for.

An incumbent with a deletion timestamp still holds what it held, and the refusal says it is
being removed. A standalone ``acl`` (an ``accessLists``-only object) binds onto a subinterface
another service owns and inherits its mode: it is neither a second owner of that (node, port,
VLAN) nor a second tagging mode — on either side of the comparison.

The pre-flight is the early, better-worded copy of the cross-object admission rules and never
the authority: a holder in ``agentic-netops-services`` is invisible here and is refused by
admission at the dry-run, after which the supervisor releases every provisional claim of the
request before the refusal is reported with the holder admission named (FR-109, AD-26). The
second-owner scan has no allocated-VLAN case: the naming band ``100-999`` and the allocation
band ``1000-4000`` are disjoint (AD-33), so both VLANs of any conflict found here are named ones.
No value is ever retried with another — a conflict is a refusal, never a re-pick.
"""

from __future__ import annotations

import json
from collections.abc import Iterable, Mapping
from pathlib import Path
from typing import Any

INVENTORY_FILE = "inventory.json"

Sub = tuple[str, str, int]  # (node, port, VLAN); VLAN 0 is the untagged subinterface <port>.0


def standalone_acl(spec: Mapping[str, Any]) -> bool:
    """An ``accessLists``-only object: the standalone ``acl`` shape."""
    return bool(spec.get("accessLists")) and not any(
        spec.get(k) for k in ("vlans", "bridgeDomains", "routers"))


def sub_of(entry: Mapping[str, Any]) -> Sub:
    return (str(entry.get("node")), str(entry.get("attachment")), int(entry.get("vlan") or 0))


def describe(sub: Sub) -> str:
    node, port, vlan = sub
    return f"(node {node}, port {port}, VLAN {vlan})" if vlan else \
        f"(node {node}, port {port}, untagged)"


def holder(obj: Mapping[str, Any], what: str) -> str:
    """``Network <ns>/<name>``, and that it is being removed when it carries a deletion
    timestamp — it holds what it held until its removal completes."""
    meta = obj.get("metadata") or {}
    key = f"{meta.get('namespace') or ''}/{meta.get('name')}"
    if meta.get("deletionTimestamp"):
        return (f"Network {key} (being removed: Network {key} is being deleted and still holds "
                f"its {what} until its removal completes)")
    return f"Network {key}"


def _mode(tagged: bool) -> str:
    return "tagged" if tagged else "untagged"


def _names(items: Iterable[str]) -> str:
    items = list(items)
    return ", ".join(items) if items else "none"


def load_inventory(directory: Path | str | None) -> dict[str, Any] | None:
    """The mounted site inventory (``SITE_INVENTORY_DIR/inventory.json``), or None when it cannot
    be read — the mapper judged the mode at interpretation and admission is the authority."""
    if directory is None:
        return None
    try:
        doc = json.loads((Path(directory) / INVENTORY_FILE).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    return doc if isinstance(doc, dict) else None


def _inventory_mode(inventory: Mapping[str, Any], sub: Sub) -> str | None:
    node, port, vlan = sub
    for entry in inventory.get("nodes") or []:
        if not isinstance(entry, Mapping) or entry.get("name") != node:
            continue
        access = [str(p) for p in entry.get("accessPorts") or []]
        untagged = [str(p) for p in entry.get("untaggedAccessPorts") or []]
        if port not in access:
            return None  # resolvability is the mapper's and admission's
        tagged = bool(vlan)
        if tagged and port in untagged:
            ports = [p for p in access if p not in untagged]
            return (f"{describe(sub)}: the site inventory declares {node} {port} untagged, and "
                    f"this attachment is tagged; the ports declared tagged on {node} are "
                    f"{_names(ports)}")
        if not tagged and port not in untagged:
            return (f"{describe(sub)}: the site inventory declares {node} {port} tagged, and "
                    f"this attachment is untagged; the ports declared untagged on {node} are "
                    f"{_names(untagged)}")
        return None
    return None


def preflight(intent: Mapping[str, Any], network: str, existing: list[dict[str, Any]], *,
              inventory: Mapping[str, Any] | None = None) -> list[str]:
    """The conflicts the intent namespace (and the site inventory) show for ``intent``, the
    assignment about to become ``Network <network>``; empty when there are none."""
    conflicts: list[str] = []
    endpoints = [e for e in intent.get("endpoints") or [] if isinstance(e, Mapping)]
    ours = list(dict.fromkeys(sub_of(e) for e in endpoints))
    acl = intent.get("acl") if isinstance(intent.get("acl"), Mapping) else None
    standalone = intent.get("type") == "acl"

    # the mode the inventory declares for each port (AD-68) — a standalone list inherits its mode
    if inventory is not None and not standalone:
        for sub in ours:
            cause = _inventory_mode(inventory, sub)
            if cause:
                conflicts.append(cause)

    for obj in existing:
        meta = obj.get("metadata") or {}
        if meta.get("name") == network:
            continue
        spec = obj.get("spec") or {}
        theirs = list(dict.fromkeys(sub_of(a) for a in spec.get("attachments") or []
                                    if isinstance(a, Mapping)))
        owner = not standalone and not standalone_acl(spec)
        if owner:
            # one owner per (node, port, VLAN)
            for sub in ours:
                if sub in theirs:
                    conflicts.append(f"{describe(sub)} is already owned by "
                                     f"{holder(obj, 'subinterfaces')}: one owner per "
                                     "(node, port, VLAN)")
            # one tagging mode per (node, port)
            reported: set[tuple[str, str]] = set()
            for node, port, vlan in ours:
                for their_node, their_port, their_vlan in theirs:
                    if (node, port) != (their_node, their_port) or \
                            bool(vlan) == bool(their_vlan) or (node, port) in reported:
                        continue
                    reported.add((node, port))
                    conflicts.append(
                        f"port {node} {port}: this request asks for a {_mode(bool(vlan))} "
                        f"attachment while {holder(obj, 'tagging mode')} holds a "
                        f"{_mode(bool(their_vlan))} one; tagging is a property of the port, one "
                        "tagging mode per port")
        # one access list per (node, port, subinterface, direction, address family)
        if acl is None:
            continue
        for their_acl in spec.get("accessLists") or []:
            if not isinstance(their_acl, Mapping) or (
                    their_acl.get("stage"), their_acl.get("type")) != (acl.get("stage"),
                                                                     acl.get("type")):
                continue
            for sub in ours:
                if sub in theirs:
                    conflicts.append(
                        f"{describe(sub)} already carries the {acl.get('stage')} "
                        f"{acl.get('type')} access list {their_acl.get('name')} of "
                        f"{holder(obj, 'access-list bindings')}: one list per (node, port, "
                        "subinterface, direction, address family) — an existing binding is never "
                        "displaced, merged into or joined by a second list")
    return list(dict.fromkeys(conflicts))


__all__ = ["INVENTORY_FILE", "describe", "holder", "load_inventory", "preflight",
           "standalone_acl", "sub_of"]
