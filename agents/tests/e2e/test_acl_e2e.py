"""T114 (the tier half) — access lists from plain language, live (quickstart.md §12 §13;
contracts/acl-render-contract.md §2 §3 §6; SC-014, SC-041, NFR-013; FR-035 to FR-043, FR-109).

One ordered scenario on the running lab, every step through ``POST /agent/prompt/stream`` as the
generated operator:

a. a ``mac-vrf`` carrying an ingress IPv4 access list converges; its ``Network`` carries
   ``accessLists[]`` with the rules in the declared priority order, and the first confirmation
   states the evaluation order (ascending priority, first match wins), the usable range 1-65534
   and — no default action declared — that unmatched traffic is accepted by the device's own
   default, never describing the list as restrictive;
b. a standalone ``acl`` (ingress IPv6, default deny — a different address family, so a different
   exclusivity key) bound to that service's leaf01 ethernet-1/1 VLAN 310 subinterface converges,
   its first confirmation stating that unmatched traffic is dropped;
c. a malformed rule set (two rules at one priority) is refused at interpretation naming the rule,
   with zero claims and no ``Network``;
d. a second standalone ``acl`` on the key (b) holds — (leaf01, ethernet-1/1, 310, ingress, ipv6)
   — is refused by the deployer's pre-flight BEFORE anything is created, naming the holder: no
   ``Network`` created and the claim set unchanged;
e. both services are removed through the tier (the standalone list first — the owner of the
   subinterface waits for the lists bound to it).

Opt-in like every live suite (``AGENTIC_NETOPS_E2E=1``, conftest.py); each step's measurement is
recorded in the run's evidence directory.
"""

from __future__ import annotations

import re
from typing import Any

import pytest
from conftest import INTENT_NS, record
from tierflow import (
    Service,
    approve_deployment,
    ask,
    claim_snapshot,
    claims_of,
    confirm_interpretation,
    network,
    networks,
    remove,
    request_to_confirmation,
)

VLAN = 310
MACVRF_WITH_ACL = (
    f"Create a mac-vrf for tenant acme that extends VLAN {VLAN} across leaf01 ethernet-1/1 and "
    "leaf02 ethernet-1/1, with an ingress ipv4 access list: rule allow-https at priority 100 "
    "permits tcp from 10.0.0.0/24 to destination port 443, and rule deny-telnet at priority 200 "
    "denies tcp to destination port 23. Declare no default action.")
STANDALONE_ACL = (
    f"Add a standalone ingress ipv6 acl for tenant acme on leaf01 ethernet-1/1 vlan {VLAN}: rule "
    "allow-nd at priority 10 permits icmpv6 from 2001:db8:310::/64, with default action deny.")
MALFORMED_ACL = (
    f"Add a standalone ingress ipv4 acl for tenant acme on leaf02 ethernet-1/1 vlan {VLAN}: rule "
    "allow-web at priority 100 permits tcp to destination port 80, and rule deny-web at "
    "priority 100 denies tcp to destination port 80.")
SECOND_ACL = (
    f"Add a standalone ingress ipv6 acl for tenant acme on leaf01 ethernet-1/1 vlan {VLAN}: rule "
    "deny-bad at priority 20 denies ipv6 traffic from 2001:db8:bad::/48.")

RESTRICTIVE = re.compile(r"deny[- ]all|denies all|restrictive|blocks? everything|"
                         r"everything else is (?:denied|dropped|blocked)", re.IGNORECASE)
ORDER = ("evaluated in ascending priority number", "first match wins", "1\u201365534")


def first_prompt(svc: Service) -> str:
    conf = svc.turns[0].confirmation()
    assert conf and conf.get("stage") == "mapper", svc.turns[0].text()
    return str(conf["prompt"])


def ready(live: dict[str, Any]) -> dict[str, Any]:
    return {c["type"]: c for c in live["status"]["conditions"]}["Ready"]


class Scenario:
    macvrf: Service | None = None
    standalone: Service | None = None


@pytest.fixture(scope="module")
def scenario() -> Any:
    state = Scenario()
    yield state
    # whatever a failed step left behind is removed through the tier, the list first
    for svc in (state.standalone, state.macvrf):
        if svc is not None and svc.network and network(svc.network) is not None:
            remove(svc.network)


def test_a_macvrf_with_an_acl_converges_with_its_rules_in_declared_order(
        scenario: Scenario) -> None:
    svc = request_to_confirmation(MACVRF_WITH_ACL)
    assert svc.interpretation and svc.interpretation["service_type"] == "mac-vrf"
    assert svc.interpretation.get("acl"), svc.interpretation
    prompt = first_prompt(svc)
    for phrase in ORDER:
        assert phrase in prompt, prompt
    assert "unmatched traffic is accepted by the device's own default" in prompt, prompt
    assert not RESTRICTIVE.search(prompt), prompt
    confirm_interpretation(svc)
    turn = approve_deployment(svc)
    assert turn.last().get("status") == "COMPLETED", turn.text()
    scenario.macvrf = svc

    live = network(svc.network or "")
    assert live is not None and ready(live)["status"] == "True", live
    (acl,) = live["spec"]["accessLists"]
    assert (acl["stage"], acl["type"]) == ("ingress", "ipv4")
    priorities = [r["priority"] for r in acl["rules"]]
    assert priorities == [100, 200] == sorted(priorities), acl["rules"]
    assert "defaultAction" not in acl, acl
    record("t114-acl-a-macvrf", {
        "network": svc.network, "correlation_id": svc.correlation_id,
        "first_confirmation": prompt, "access_lists": live["spec"]["accessLists"],
        "ready": ready(live), "approval_to_converged_seconds": svc.approval_to_converged_s})


def test_a_standalone_acl_on_that_services_subinterface_converges(scenario: Scenario) -> None:
    assert scenario.macvrf is not None, "step (a) did not converge"
    svc = request_to_confirmation(STANDALONE_ACL)
    assert svc.interpretation and svc.interpretation["service_type"] == "acl"
    prompt = first_prompt(svc)
    for phrase in ORDER:
        assert phrase in prompt, prompt
    assert "unmatched traffic is dropped by the declared default action" in prompt, prompt
    confirm_interpretation(svc)
    assert svc.assignment and svc.assignment["type"] == "acl"
    turn = approve_deployment(svc)
    assert turn.last().get("status") == "COMPLETED", turn.text()
    scenario.standalone = svc

    live = network(svc.network or "")
    assert live is not None and ready(live)["status"] == "True", live
    spec = live["spec"]
    assert not any(spec.get(k) for k in ("vlans", "bridgeDomains", "routers")), spec
    (acl,) = spec["accessLists"]
    assert (acl["stage"], acl["type"], acl.get("defaultAction")) == ("ingress", "ipv6", "deny")
    assert [(a["node"], a["attachment"], a.get("vlan")) for a in spec["attachments"]] == [
        ("leaf01", "ethernet-1/1", VLAN)]
    assert claims_of(svc.correlation_id) == []  # a standalone list claims nothing
    record("t114-acl-b-standalone", {
        "network": svc.network, "correlation_id": svc.correlation_id,
        "first_confirmation": prompt, "spec": spec, "ready": ready(live),
        "approval_to_converged_seconds": svc.approval_to_converged_s})


def test_a_malformed_rule_set_is_refused_naming_the_rule_with_zero_claims() -> None:
    claims_before, networks_before = claim_snapshot(), set(networks())
    turn = ask(MALFORMED_ACL)
    final = turn.last()
    text = turn.text()
    assert final.get("status") == "FAILED", text
    assert turn.confirmation() is None, text  # refused at interpretation, nothing to confirm
    assert re.search(r"acl\.rules\[\d\]\.priority: 100 is already the priority of rule", text), \
        text
    assert claim_snapshot() == claims_before
    assert claims_of(turn.correlation_id) == []
    assert set(networks()) == networks_before
    record("t114-acl-c-malformed", {"correlation_id": turn.correlation_id, "final": final})


def test_a_second_list_on_a_held_binding_is_refused_before_anything_is_created(
        scenario: Scenario) -> None:
    holder = scenario.standalone
    assert holder is not None and holder.network, "step (b) did not converge"
    claims_before, networks_before = claim_snapshot(), set(networks())
    svc = request_to_confirmation(SECOND_ACL)
    confirm_interpretation(svc)
    turn = approve_deployment(svc)
    final = turn.last()
    text = turn.text()
    assert final.get("status") == "FAILED", text
    assert f"Network {INTENT_NS}/{holder.network}" in text, text
    assert "refused by the pre-flight" in text, text
    assert "already carries the ingress ipv6 access list" in text, text
    # nothing created: no Network, the claim set unchanged, nothing held under this request
    assert set(networks()) == networks_before
    assert svc.network is None or network(svc.network) is None
    assert claim_snapshot() == claims_before
    assert claims_of(svc.correlation_id) == []
    record("t114-acl-d-binding-conflict", {
        "holder": f"Network {INTENT_NS}/{holder.network}", "correlation_id": svc.correlation_id,
        "final": final})


def test_both_are_removed_through_the_tier(scenario: Scenario) -> None:
    removed = {}
    for svc in (scenario.standalone, scenario.macvrf):
        assert svc is not None and svc.network
        turns = remove(svc.network)
        final = turns[-1].last()
        assert final.get("status") == "COMPLETED", turns[-1].text()
        assert network(svc.network) is None
        assert claims_of(svc.correlation_id) == []
        removed[svc.network] = final
    record("t114-acl-e-removal", {"removed": removed})

