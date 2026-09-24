"""T111 — the first confirmation of a request carrying an access list states, in words, the
evaluation order (ascending priority number, first match wins), the usable priority range
1-65534 and what happens to traffic no rule matches: with no default action declared it is
ACCEPTED by the device's own default, and the list is never described as restrictive; with a
declared deny it is dropped (contracts/acl-render-contract.md §2, construct-vocabulary.md §3.1;
FR-039, FR-041).

Asserted on the wording function and on the ``confirmation_request`` chunk the supervisor graph
emits after the mapper (the fake-worker rig of test_audit_emission.py).
"""

from __future__ import annotations

import re
from typing import Any

import pytest

from supervisors.provisioning.graph.confirmations import interpretation_prompt
from tests.unit.test_audit_emission import Rig, confirmations
from tests.unit.test_audit_emission import rig as rig

pytestmark = pytest.mark.usefixtures("fresh_telemetry")

RESTRICTIVE = re.compile(r"deny[- ]all|denies all|restrictive|blocks? everything|"
                         r"everything else is (?:denied|dropped|blocked)|default[- ]deny|"
                         r"only .* (?:is|are) (?:allowed|permitted)", re.IGNORECASE)


def acl_interpretation(construct: str = "acl", default: str | None = None) -> dict[str, Any]:
    acl: dict[str, Any] = {
        "stage": "ingress", "type": "ipv4",
        "evaluation_order": "ascending-first-match",
        "unmatched_traffic": default or "accept-platform-default",
        "rules": [{"name": "allow-https", "priority": 100, "action": "permit",
                   "protocol": "tcp", "destination_port": "443"},
                  {"name": "deny-telnet", "priority": 200, "action": "deny",
                   "protocol": "tcp", "destination_port": "23"}]}
    if default is not None:
        acl["default_action"] = default
    return {"service_id": "3f2b9c0d1e4a5b6", "service_type": construct, "tenant": "blue",
            "endpoints": [{"site_or_node": "leaf01", "attachment": "ethernet-1/1", "vlan": 310}],
            "acl": acl}


def assert_order_and_range(prompt: str) -> None:
    assert "evaluated in ascending priority number" in prompt, prompt
    assert "first match wins" in prompt, prompt
    assert "1\u201365534" in prompt, prompt
    assert "65535 is reserved for the default action" in prompt, prompt


@pytest.mark.parametrize("construct", ["acl", "mac-vrf", "vlan", "ip-vrf"])
def test_no_default_action_says_unmatched_traffic_is_accepted_and_never_restrictive(
        construct: str) -> None:
    prompt = interpretation_prompt(acl_interpretation(construct))
    assert prompt.startswith(f"Confirm this {construct} interpretation?")
    assert_order_and_range(prompt)
    assert "unmatched traffic is accepted by the device's own default" in prompt
    assert "no default action is declared" in prompt
    assert not RESTRICTIVE.search(prompt), prompt
    assert "dropped" not in prompt


def test_a_declared_deny_says_unmatched_traffic_is_dropped() -> None:
    prompt = interpretation_prompt(acl_interpretation(default="deny"))
    assert_order_and_range(prompt)
    assert "unmatched traffic is dropped by the declared default action" in prompt
    assert "accepted by the device's own default" not in prompt


def test_a_declared_permit_says_unmatched_traffic_is_accepted_by_the_terminal_entry() -> None:
    prompt = interpretation_prompt(acl_interpretation(default="permit"))
    assert_order_and_range(prompt)
    assert "unmatched traffic is accepted by the declared default action" in prompt


def test_a_request_without_an_acl_says_nothing_about_rules() -> None:
    wire = acl_interpretation("mac-vrf")
    del wire["acl"]
    prompt = interpretation_prompt(wire)
    assert "priority" not in prompt and "unmatched" not in prompt


@pytest.mark.parametrize(("default", "phrase"), [
    (None, "unmatched traffic is accepted by the device's own default"),
    ("deny", "unmatched traffic is dropped by the declared default action")])
async def test_the_first_confirmation_chunk_carries_the_statements(
        rig: Rig, default: str | None, phrase: str) -> None:
    rig.client.interpretation = acl_interpretation(default=default)
    chunks = await rig.turn("permit tcp 443 on leaf01 ethernet-1/1 vlan 310 for tenant blue")
    (first,) = confirmations(chunks)
    assert first["stage"] == "mapper"
    prompt = first["prompt"]
    assert_order_and_range(prompt)
    assert phrase in prompt
    if default is None:
        assert not RESTRICTIVE.search(prompt), prompt
