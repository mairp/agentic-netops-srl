"""T112 — the deployer's binding pre-flight (contracts/kubernetes-objects.md §"Submission
contract" step 1, acl-render-contract.md §6; FR-034, FR-043, FR-062, FR-109; AD-20, AD-26, AD-33,
AD-68).

Scanned: ``agentic-netops-intent`` only. Refused before anything is created, naming the incumbent
``Network <ns>/<name>`` (and that it is being removed when it carries a deletion timestamp): a
second owner of a (node, port, VLAN), a conflicting tagging mode on a (node, port), a second
access list on an exclusivity key (node, port, subinterface, direction, address family), and a
mode other than the site inventory declares for the port (listing the ports declared in the mode
asked for). IPv4 beside IPv6, or different subinterfaces, do not conflict; a standalone ``acl``
bound onto another service's subinterface is neither a second owner nor a second tagging mode. A
holder the pre-flight cannot see (``agentic-netops-services``) is refused by admission at the
dry-run: nothing is applied, the holder admission named is reported, and every provisional claim
of the request is released before the refusal reaches the operator.
"""

from __future__ import annotations

import copy
import json
from pathlib import Path
from typing import Any

import pytest

from provisioning.deployer.preflight import load_inventory, preflight
from provisioning.deployer.submit import preflight as reexported
from tests.unit.deployer_fakes import (
    ASSIGNMENT,
    CID,
    CONFIRM,
    NS,
    OTHER_CID,
    SERVICES_NS,
    Rig,
)
from tests.unit.test_audit_emission import PROMPT, confirmations, finals
from tests.unit.test_audit_emission import Rig as SupervisorRig
from tests.unit.test_audit_emission import rig as rig

pytestmark = pytest.mark.usefixtures("fresh_telemetry")

ACL_SID = "a1c0000000000b1"
ACL_NETWORK = f"migr-{ACL_SID}"
HOLDER_SID = "0123456789abcde"
HOLDER = f"migr-{HOLDER_SID}"
RULES = [{"name": "allow-https", "priority": 100, "action": "permit", "protocol": "tcp",
          "destinationPort": "443"}]
INVENTORY = {"fabricASN": 65000, "nodes": [
    {"name": "leaf01", "role": "leaf", "accessPorts": ["ethernet-1/1", "ethernet-1/2",
                                                       "ethernet-1/3"],
     "untaggedAccessPorts": ["ethernet-1/3"]},
    {"name": "leaf02", "role": "leaf", "accessPorts": ["ethernet-1/1"],
     "untaggedAccessPorts": []},
    {"name": "spine01", "role": "spine", "accessPorts": [], "untaggedAccessPorts": []}]}


def acl_intent(vlan: int | None = 310, *, stage: str = "ingress", family: str = "ipv4",
               sid: str = ACL_SID, node: str = "leaf01", port: str = "ethernet-1/1"
               ) -> dict[str, Any]:
    endpoint: dict[str, Any] = {"node": node, "attachment": port}
    if vlan is not None:
        endpoint["vlan"] = vlan
    return {"serviceId": sid, "type": "acl", "tenant": "blue",
            "acl": {"stage": stage, "type": family, "rules": copy.deepcopy(RULES)},
            "endpoints": [endpoint]}


def service(name: str, *attachments: tuple[str, str, int | None], deleting: bool = False,
            namespace: str = NS, lists: list[tuple[str, str]] = ()) -> dict[str, Any]:
    """A live Network: a bridged service (``bridgeDomains``) or, with ``lists`` and nothing
    else, a standalone access list."""
    atts = []
    for node, port, vlan in attachments:
        a: dict[str, Any] = {"node": node, "attachment": port}
        if vlan is not None:
            a["vlan"] = vlan
        atts.append(a)
    spec: dict[str, Any] = {"attachments": atts}
    sid = name.removeprefix("migr-")
    if lists:
        spec["accessLists"] = [{"name": f"acl-{sid}-{stage}", "stage": stage, "type": family,
                                "rules": copy.deepcopy(RULES)} for stage, family in lists]
    else:
        spec["bridgeDomains"] = [{"name": f"bd-{sid}", "vlan": attachments[0][2] or 0}]
    meta: dict[str, Any] = {"name": name, "namespace": namespace,
                            "labels": {"agentic-netops.io/correlation-id": OTHER_CID}}
    if deleting:
        meta["deletionTimestamp"] = "2026-09-24T11:59:00Z"
    return {"metadata": meta, "spec": spec}


def standalone_holder(**kw: Any) -> dict[str, Any]:
    return service(HOLDER, ("leaf01", "ethernet-1/1", 310), lists=[("ingress", "ipv4")], **kw)


def owner(name: str = "migr-00000000000000a", vlan: int | None = 310) -> dict[str, Any]:
    return service(name, ("leaf01", "ethernet-1/1", vlan), ("leaf02", "ethernet-1/1", vlan))


def macvrf_intent(vlan: int = 120, **extra: Any) -> dict[str, Any]:
    body = copy.deepcopy(ASSIGNMENT)
    for e in body["endpoints"]:
        e["vlan"] = vlan
    body.update(extra)
    return body


# ---- the move: submit.py re-exports it -------------------------------------------------------


def test_submit_reexports_the_preflight() -> None:
    assert reexported is preflight


# ---- one owner per (node, port, VLAN), one tagging mode per port ----------------------------


def test_a_second_owner_is_refused_naming_the_incumbent() -> None:
    intent = macvrf_intent(310)
    intent["endpoints"] = intent["endpoints"][:1]
    (cause,) = preflight(intent, "migr-new", [owner()])
    assert cause == (f"(node leaf01, port ethernet-1/1, VLAN 310) is already owned by Network "
                     f"{NS}/migr-00000000000000a: one owner per (node, port, VLAN)")


def test_both_endpoints_of_a_second_owner_are_named() -> None:
    found = preflight(macvrf_intent(310), "migr-new", [owner()])
    assert [c.split(" is already")[0] for c in found] == [
        "(node leaf01, port ethernet-1/1, VLAN 310)", "(node leaf02, port ethernet-1/1, VLAN 310)"]
    assert all(f"Network {NS}/migr-00000000000000a" in c for c in found)


def test_a_deleting_incumbent_still_holds_and_the_refusal_says_it_is_being_removed() -> None:
    incumbent = service("migr-00000000000000a", ("leaf01", "ethernet-1/1", 310), deleting=True)
    (cause,) = preflight(macvrf_intent(310), "migr-new", [incumbent])
    assert f"Network {NS}/migr-00000000000000a (being removed" in cause
    assert "still holds its subinterfaces until its removal completes" in cause


def test_a_conflicting_tagging_mode_on_a_port_is_refused_naming_the_holder() -> None:
    untagged = service("migr-00000000000000u", ("leaf01", "ethernet-1/1", None))
    (cause,) = preflight(macvrf_intent(120), "migr-new", [untagged])
    assert cause == (f"port leaf01 ethernet-1/1: this request asks for a tagged attachment while "
                     f"Network {NS}/migr-00000000000000u holds a untagged one; tagging is a "
                     "property of the port, one tagging mode per port")


def test_different_vlans_on_one_tagged_port_do_not_conflict() -> None:
    assert preflight(macvrf_intent(120), "migr-new", [owner(vlan=130)]) == []


def test_the_request_never_conflicts_with_its_own_network() -> None:
    assert preflight(macvrf_intent(310), "migr-00000000000000a", [owner()]) == []


# ---- the access-list exclusivity key ---------------------------------------------------------


def test_a_second_list_on_the_same_key_is_refused_naming_the_holder_and_its_list() -> None:
    (cause,) = preflight(acl_intent(), ACL_NETWORK, [owner(), standalone_holder()])
    assert cause == (
        f"(node leaf01, port ethernet-1/1, VLAN 310) already carries the ingress ipv4 access "
        f"list acl-{HOLDER_SID}-ingress of Network {NS}/{HOLDER}: one list per (node, port, "
        "subinterface, direction, address family) — an existing binding is never displaced, "
        "merged into or joined by a second list")


def test_a_list_carried_by_the_owning_service_is_a_holder_too() -> None:
    carrying = service("migr-00000000000000a", ("leaf01", "ethernet-1/1", 310),
                       lists=[("ingress", "ipv4")])
    carrying["spec"]["bridgeDomains"] = [{"name": "bd-00000000000000a", "vlan": 310}]
    (cause,) = preflight(acl_intent(), ACL_NETWORK, [carrying])
    assert "already carries the ingress ipv4 access list" in cause
    assert f"Network {NS}/migr-00000000000000a" in cause


def test_a_deleting_holder_of_a_binding_is_named_as_being_removed() -> None:
    (cause,) = preflight(acl_intent(), ACL_NETWORK, [owner(), standalone_holder(deleting=True)])
    assert f"Network {NS}/{HOLDER} (being removed" in cause
    assert "still holds its access-list bindings" in cause


@pytest.mark.parametrize(("intent", "why"), [
    (acl_intent(family="ipv6"), "IPv6 beside IPv4 on one subinterface"),
    (acl_intent(vlan=320), "another subinterface of the same port"),
    (acl_intent(vlan=None), "the untagged subinterface of the same port"),
    (acl_intent(stage="egress"), "the other direction"),
    (acl_intent(node="leaf02"), "another node"),
])
def test_what_is_not_the_same_key_does_not_conflict(intent: dict[str, Any], why: str) -> None:
    assert preflight(intent, ACL_NETWORK, [owner(), owner("migr-00000000000000b", 320),
                                           standalone_holder()]) == [], why


def test_a_standalone_list_on_another_services_subinterface_is_neither_owner_nor_mode() -> None:
    # the service owns leaf01 ethernet-1/1.310; untagged services hold nothing here
    assert preflight(acl_intent(), ACL_NETWORK, [owner()]) == []
    # and a later service is not a second owner of a subinterface a standalone list binds to
    assert preflight(macvrf_intent(310), "migr-new", [standalone_holder()]) == []
    # nor a second tagging mode, whichever side the standalone list is on
    untagged_list = service(HOLDER, ("leaf01", "ethernet-1/1", None),
                            lists=[("ingress", "ipv4")])
    assert preflight(macvrf_intent(310), "migr-new", [untagged_list]) == []
    assert preflight(acl_intent(vlan=None), ACL_NETWORK, [owner()]) == []


# ---- the mode the site inventory declares (AD-68) --------------------------------------------


def test_a_tagged_attachment_on_a_port_declared_untagged_lists_the_tagged_ports() -> None:
    intent = macvrf_intent(120)
    intent["endpoints"][0]["attachment"] = "ethernet-1/3"
    (cause,) = preflight(intent, "migr-new", [], inventory=INVENTORY)
    assert cause == ("(node leaf01, port ethernet-1/3, VLAN 120): the site inventory declares "
                     "leaf01 ethernet-1/3 untagged, and this attachment is tagged; the ports "
                     "declared tagged on leaf01 are ethernet-1/1, ethernet-1/2")


def test_an_untagged_attachment_on_a_port_declared_tagged_lists_the_untagged_ports() -> None:
    intent = {"serviceId": "b0b", "type": "ip-vrf", "tenant": "blue", "l3vni": 10500,
              "endpoints": [{"node": "leaf02", "attachment": "ethernet-1/1"}]}
    (cause,) = preflight(intent, "migr-b0b", [], inventory=INVENTORY)
    assert cause == ("(node leaf02, port ethernet-1/1, untagged): the site inventory declares "
                     "leaf02 ethernet-1/1 tagged, and this attachment is untagged; the ports "
                     "declared untagged on leaf02 are none")


def test_a_standalone_list_inherits_the_mode_and_is_not_judged_on_it() -> None:
    assert preflight(acl_intent(vlan=None), ACL_NETWORK, [], inventory=INVENTORY) == []


def test_the_inventory_is_read_from_the_mounted_directory(tmp_path: Path) -> None:
    (tmp_path / "inventory.json").write_text(json.dumps(INVENTORY))
    assert load_inventory(tmp_path) == INVENTORY
    assert load_inventory(tmp_path / "absent") is None
    assert load_inventory(None) is None


# ---- through the deployer stage: before anything is created ---------------------------------


async def create(rig_: Rig, assignment: dict[str, Any]) -> Any:
    return await rig_.call({"operation": "create", "assignment": assignment,
                            "principal": "alice", "confirmation_2": CONFIRM})


async def test_a_binding_conflict_is_refused_before_anything_is_created() -> None:
    rig_ = Rig()
    rig_.api.put(owner())
    rig_.api.put(standalone_holder())
    before = set(rig_.api.networks)
    report = await create(rig_, acl_intent())
    assert report.status == "FAILED" and report.submitted is False
    assert f"Network {NS}/{HOLDER}" in (report.message or "")
    assert report.message.startswith("refused by the pre-flight")
    assert any("already carries the ingress ipv4 access list" in c for c in report.causes)
    # nothing created, nothing translated, nothing dry-run; no value retried with another
    assert rig_.translator.calls == [] and rig_.api.calls("PATCH") == []
    assert set(rig_.api.networks) == before
    gate = await rig_.gate(CID)
    assert gate.releasable == [CID]


async def test_the_stage_judges_the_mode_the_mounted_inventory_declares(tmp_path: Path) -> None:
    (tmp_path / "inventory.json").write_text(json.dumps(INVENTORY))
    rig_ = Rig(SITE_INVENTORY_DIR=str(tmp_path))
    assignment = macvrf_intent(120)
    assignment["endpoints"][0]["attachment"] = "ethernet-1/3"
    report = await create(rig_, assignment)
    assert report.status == "FAILED" and report.submitted is False
    assert "the ports declared tagged on leaf01 are ethernet-1/1, ethernet-1/2" in report.message
    assert rig_.translator.calls == [] and rig_.api.calls("PATCH") == []


ADMISSION_ACL = (
    'admission webhook "networks.fabric.agentic-netops.io" denied the request: access list '
    f"acl-{ACL_SID}-ingress: subinterface leaf01 ethernet-1/1.310 already carries the ingress "
    f"ipv4 access list acl-lab-ingress of Network {SERVICES_NS}/lab-acl; one list per "
    "subinterface, direction and address family")


async def test_an_acl_holder_only_admission_sees_is_refused_at_the_dry_run_naming_it() -> None:
    """The holder lives in agentic-netops-services: invisible to the pre-flight, refused by the
    cross-object admission rules at the dry-run — nothing applied, nothing to roll back, the
    holder admission named reported, the id releasable."""
    rig_ = Rig()
    rig_.api.put(owner())
    rig_.api.reject[ACL_NETWORK] = ADMISSION_ACL
    report = await create(rig_, acl_intent())
    assert report.status == "FAILED" and report.submitted is False
    assert report.retryable is False
    assert f"holder: Network {SERVICES_NS}/lab-acl" in (report.causes or [])
    assert f"{SERVICES_NS}/lab-acl" in (report.message or "")
    assert rig_.api.network_writes() == [] and rig_.api.calls("DELETE") == []
    assert len(rig_.translator.calls) == 1  # translated once; no value retried with another
    gate = await rig_.gate(CID)
    assert gate.releasable == [CID]


async def test_every_provisional_claim_is_released_before_the_admission_refusal_is_reported(
        rig: SupervisorRig) -> None:
    """The supervisor's half of FR-109: a refusal before apply releases the request's claims
    (release gate, then the allocator) and only then reports, naming the holder."""
    rig.client.create_report = {
        "operation": "create", "status": "FAILED", "submitted": False,
        "causes": [ADMISSION_ACL, f"holder: Network {SERVICES_NS}/lab-acl"],
        "message": f"refused: the server-side dry-run rejected Network/{ACL_NETWORK}: "
                   f"{ADMISSION_ACL} — the whole bundle is aborted and nothing was applied"}
    thread_id = (await rig.turn(PROMPT))[0]["thread_id"]
    await rig.turn("confirm", thread_id)
    chunks = await rig.turn("confirm", thread_id)
    assert len(confirmations(rig.chunks)) == 2
    ops = rig.client.ops()
    create_at = ops.index(("deploy-network-service", "create"))
    assert ops[create_at + 1:] == [("deploy-network-service", "release_gate"),
                                   ("allocate-network-service", "release")]
    final = finals(chunks)[-1]
    assert final["status"] == "FAILED"
    assert f"Network {SERVICES_NS}/lab-acl" in json.dumps(final)
    assert "released" in json.dumps(final)
