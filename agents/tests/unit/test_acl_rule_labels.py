"""Rule names and unstated priorities of an access list (mapper pass 1, T144 live finding).

A rule's name is a label (construct-vocabulary.md §acl): one the operator did not give is derived
from what the rule states. A priority the operator did not give is the stated order when no rule
states one, and is asked for — never guessed — when only some do (FR-059)."""
from __future__ import annotations

from typing import Any

from provisioning.mapper import acl


def _data(rules: list[dict[str, Any]], missing: list[str] | None = None) -> dict[str, Any]:
    return {"acl": {"type": "ipv4", "stage": "ingress", "rules": rules},
            "missing_fields": list(missing or [])}


def test_unnamed_unordered_rules_are_labelled_and_ordered_as_stated() -> None:
    data = _data([{"name": None, "priority": None, "action": "permit", "protocol": "tcp",
                   "destination_port": "443"},
                  {"name": "unknown", "priority": "unknown", "action": "deny", "protocol": "tcp",
                   "destination_port": "23"}],
                 ["acl.rules[0].name", "acl.rules[0].priority", "acl.rules[1].name"])
    assert acl.prepare(data) == []
    rules = data["acl"]["rules"]
    assert [r["priority"] for r in rules] == [10, 20]
    assert [r["name"] for r in rules] == ["permit-tcp-443", "deny-tcp-23"]
    assert data["missing_fields"] == []


def test_stated_priorities_are_kept_and_duplicate_labels_are_made_distinct() -> None:
    data = _data([{"priority": 10, "action": "deny", "protocol": "udp", "destination_port": "53"},
                  {"priority": "20", "action": "deny", "protocol": "udp",
                   "destination_port": "53"}])
    acl.prepare(data)
    rules = data["acl"]["rules"]
    assert [r["priority"] for r in rules] == [10, 20]
    assert [r["name"] for r in rules] == ["deny-udp-53", "deny-udp-53-2"]


def test_an_operator_name_is_never_replaced() -> None:
    data = _data([{"name": "web", "priority": 5, "action": "permit", "protocol": "tcp"}])
    acl.prepare(data)
    assert data["acl"]["rules"][0]["name"] == "web"


def test_a_priority_stated_for_some_rules_only_is_asked_for() -> None:
    data = _data([{"priority": 10, "action": "permit", "protocol": "tcp"},
                  {"priority": None, "action": "deny", "protocol": "tcp"}])
    acl.prepare(data)
    assert data["missing_fields"] == ["acl.rules[1].priority"]
    # the stand-in keeps the schema whole and collides with nothing stated
    assert data["acl"]["rules"][1]["priority"] not in (10, None)
