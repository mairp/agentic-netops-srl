"""T118 (the tier half) — a gateway without asking for a different service, live (User Story 8;
contracts/construct-vocabulary.md §3, kuid-claim-profiles.md §2-§4, data-model.md §8/§10;
FR-032, CR-002).

Three independent scenarios on the running lab, every step through ``POST /agent/prompt/stream``
as the generated operator (tenant ``acme``, VLANs from the naming band):

1. a ``mac-vrf`` with an anycast gateway declaring both families (VLAN 170, ``10.170.0.1/24`` and
   ``2001:db8:170::1/64``, leaf01 + leaf02 ethernet-1/1) converges as bridge domain **plus** routed
   instance: its ``Network`` carries ``bridgeDomains[0].irb`` naming ``routers[0]`` with both
   families; the operator is never asked for another construct type — every interpretation and
   assignment the stream carries is a ``mac-vrf`` and no clarification asks for a service type;
   one L2VNI and one L3VNI claim are held under the thread's correlation label;
2. a gateway naming only IPv4 (VLAN 171, ``10.171.0.1/24``): the ``irb`` carries ``gatewayIPv4``
   only and ``routers[0].prefixes`` only IPv4 prefixes — no unrequested family on either instance;
3. a ``mac-vrf`` with no gateway (VLAN 172): no ``routers[]``, no ``irb``, and the L3VNI claim
   selector (the correlation label's claims named ``.l3vni-``) is empty.

Each service is removed through the tier at the end (both confirmations) and its L3VNI claim
selector is empty afterwards. Reachability of the gateway from the attached ports is the
integrator's ``tests/integration/traffic.sh`` case, never pinged from here. Opt-in like every live
suite (``AGENTIC_NETOPS_E2E=1``, conftest.py); each scenario is recorded in the evidence directory.
"""

from __future__ import annotations

import ipaddress
import time
from collections.abc import Iterator
from typing import Any

from conftest import record
from tierflow import (
    Service,
    approve_deployment,
    claims_of,
    confirm_interpretation,
    network,
    remove,
    request_to_confirmation,
)

TENANT = "acme"
PORTS = "leaf01 ethernet-1/1 and leaf02 ethernet-1/1"
DUAL_STACK = (f"Create a mac-vrf for tenant {TENANT} that extends VLAN 170 across {PORTS}, with "
              "an anycast gateway 10.170.0.1/24 and 2001:db8:170::1/64")
IPV4_ONLY = (f"Create a mac-vrf for tenant {TENANT} that extends VLAN 171 across {PORTS}, with "
             "an IPv4 anycast gateway 10.171.0.1/24")
NO_GATEWAY = f"Create a mac-vrf for tenant {TENANT} that extends VLAN 172 across {PORTS}"
RELEASE_S = 300.0


# --------------------------------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------------------------------


def provisioned(prompt: str) -> Service:
    svc = request_to_confirmation(prompt)
    confirm_interpretation(svc)
    turn = approve_deployment(svc)
    assert turn.last().get("status") == "COMPLETED", f"not converged:\n{turn.text()}"
    assert svc.network, turn.text()
    return svc


def dicts(value: Any) -> Iterator[dict[str, Any]]:
    if isinstance(value, dict):
        yield value
        for v in value.values():
            yield from dicts(v)
    elif isinstance(value, list):
        for v in value:
            yield from dicts(v)


def assert_never_asked_for_another_type(svc: Service) -> None:
    """Construct vocabulary throughout: every interpretation is a mac-vrf, every assignment a
    mac-vrf, and nothing asks the operator for a service type or refuses one construct in favour
    of another (CR-002)."""
    types: set[str] = set()
    for turn in svc.turns:
        for d in dicts(turn.chunks):
            if isinstance(d.get("service_type"), str):
                types.add(d["service_type"])
            if d.get("type") in ("mac-vrf", "ip-vrf", "vlan", "acl") and "serviceId" in d:
                types.add(d["type"])
            missing = d.get("missing_fields")
            if isinstance(missing, list):
                assert not [m for m in missing if "service_type" in str(m)], d
            unsupported = d.get("unsupported_properties")
            if isinstance(unsupported, list):
                assert unsupported == [], d
        text = turn.text().lower()
        assert "one construct per request" not in text, turn.text()
        assert "service_type: 'ip-vrf'" not in text, turn.text()
    assert types == {"mac-vrf"}, types


def ready(live: dict[str, Any]) -> dict[str, Any]:
    return {c["type"]: c for c in live["status"]["conditions"]}["Ready"]


def names(claims: list[dict[str, Any]]) -> list[str]:
    return sorted(c["metadata"]["name"] for c in claims)


def l3vni_selector(correlation_id: str) -> list[str]:
    return [n for n in names(claims_of(correlation_id)) if ".l3vni-" in n]


def l2vni_selector(correlation_id: str) -> list[str]:
    return [n for n in names(claims_of(correlation_id)) if ".l2vni-" in n]


def removed(svc: Service) -> dict[str, Any]:
    """Remove through the tier and wait for the service's claims to be released."""
    assert svc.network
    removal = remove(svc.network)
    final = removal[-1].last()
    assert final.get("status") == "COMPLETED", removal[-1].text()
    assert network(svc.network) is None
    deadline = time.monotonic() + RELEASE_S
    while l3vni_selector(svc.correlation_id) and time.monotonic() < deadline:
        time.sleep(3)
    assert l3vni_selector(svc.correlation_id) == []
    return final


def families(prefixes: list[str]) -> set[int]:
    return {ipaddress.ip_network(p, strict=False).version for p in prefixes}


# --------------------------------------------------------------------------------------------------
# the scenarios
# --------------------------------------------------------------------------------------------------


def test_a_macvrf_with_a_dual_stack_gateway_converges_as_both_instances() -> None:
    svc = provisioned(DUAL_STACK)
    try:
        assert svc.interpretation and svc.interpretation["service_type"] == "mac-vrf"
        assert svc.interpretation["anycast_gateway"] == {"ipv4": "10.170.0.1/24",
                                                         "ipv6": "2001:db8:170::1/64"}
        assert svc.assignment and svc.assignment["type"] == "mac-vrf"
        assert svc.assignment["anycastGateway"] == {"gatewayIPv4": "10.170.0.1/24",
                                                    "gatewayIPv6": "2001:db8:170::1/64"}
        assert_never_asked_for_another_type(svc)

        live = network(svc.network or "")
        assert live is not None and ready(live)["status"] == "True", live
        spec = live["spec"]
        (bd,) = spec["bridgeDomains"]
        (router,) = spec["routers"]
        assert bd["vlan"] == 170
        assert bd["irb"]["vrf"] == router["name"]
        assert bd["irb"].get("gatewayIPv4") == "10.170.0.1/24"
        assert bd["irb"].get("gatewayIPv6") == "2001:db8:170::1/64"
        assert router["l3vni"] == svc.assignment["l3vni"] and bd["l2vni"] == svc.assignment["l2vni"]
        assert families(router.get("prefixes") or []) == {4, 6}

        l2, l3 = l2vni_selector(svc.correlation_id), l3vni_selector(svc.correlation_id)
        assert len(l2) == 1 and len(l3) == 1, names(claims_of(svc.correlation_id))
        held = names(claims_of(svc.correlation_id))
    finally:
        final = removed(svc) if svc.network else None
    record("t118-gateway-dual-stack", {
        "network": svc.network, "correlation_id": svc.correlation_id, "spec": spec,
        "claims_while_live": held, "l3vni_selector_after_removal":
            l3vni_selector(svc.correlation_id), "removal_final": final})


def test_an_ipv4_only_gateway_configures_no_unrequested_family() -> None:
    svc = provisioned(IPV4_ONLY)
    try:
        assert svc.interpretation and svc.interpretation["service_type"] == "mac-vrf"
        assert not (svc.interpretation.get("anycast_gateway") or {}).get("ipv6")
        assert svc.assignment and svc.assignment["anycastGateway"] == {
            "gatewayIPv4": "10.171.0.1/24"}
        assert_never_asked_for_another_type(svc)

        live = network(svc.network or "")
        assert live is not None and ready(live)["status"] == "True", live
        spec = live["spec"]
        (bd,) = spec["bridgeDomains"]
        (router,) = spec["routers"]
        assert bd["vlan"] == 171 and bd["irb"]["vrf"] == router["name"]
        # no unrequested family on either instance (FR-032)
        assert bd["irb"].get("gatewayIPv4") == "10.171.0.1/24"
        assert "gatewayIPv6" not in bd["irb"], bd["irb"]
        assert router.get("prefixes"), router
        assert families(router["prefixes"]) == {4}, router["prefixes"]
        assert len(l3vni_selector(svc.correlation_id)) == 1
        held = names(claims_of(svc.correlation_id))
    finally:
        final = removed(svc) if svc.network else None
    record("t118-gateway-ipv4-only", {
        "network": svc.network, "correlation_id": svc.correlation_id, "spec": spec,
        "claims_while_live": held, "removal_final": final})


def test_a_macvrf_without_a_gateway_has_no_routed_instance_and_no_l3_identifier() -> None:
    svc = provisioned(NO_GATEWAY)
    try:
        assert svc.interpretation and svc.interpretation["service_type"] == "mac-vrf"
        assert svc.interpretation.get("anycast_gateway") is None
        assert svc.assignment and svc.assignment["type"] == "mac-vrf"
        assert "anycastGateway" not in svc.assignment and "l3vni" not in svc.assignment
        assert_never_asked_for_another_type(svc)

        live = network(svc.network or "")
        assert live is not None and ready(live)["status"] == "True", live
        spec = live["spec"]
        assert not spec.get("routers"), spec
        (bd,) = spec["bridgeDomains"]
        assert bd["vlan"] == 172 and "irb" not in bd, bd
        assert l3vni_selector(svc.correlation_id) == []  # the empty L3VNI claim selector
        assert len(l2vni_selector(svc.correlation_id)) == 1
        held = names(claims_of(svc.correlation_id))
    finally:
        final = removed(svc) if svc.network else None
    record("t118-gateway-none", {
        "network": svc.network, "correlation_id": svc.correlation_id, "spec": spec,
        "claims_while_live": held, "removal_final": final})
