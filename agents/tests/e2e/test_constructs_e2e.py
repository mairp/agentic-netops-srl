"""T103 — one prompt per construct, through both confirmations, converged (quickstart.md §11;
SC-011, SC-021, SC-023).

Each construct is asked for in plain language through ``POST /agent/prompt/stream``; the test
answers the two confirmations the way an operator does and measures the wall-clock from the
approval (the second confirmation) to the converged final chunk — operator time excluded — which
must be at most five minutes. The services are removed again through the tier (both
confirmations), and the removal must end ``COMPLETED`` with the object gone. What the allocator
assigned is kept for ``test_golden_equivalence.py``.
"""

from __future__ import annotations

import json
import os
from pathlib import Path

import pytest
from conftest import record
from tierflow import (
    claims_of,
    network,
    provision,
    remove,
)

CONSTRUCTS = {
    "vlan": "Create a vlan for tenant acme on leaf01 ethernet-1/1 and leaf02 ethernet-1/1 "
            "with VLAN 100",
    "mac-vrf": "Create a mac-vrf for tenant acme that extends VLAN 100 across leaf01 "
               "ethernet-1/1 and leaf02 ethernet-1/1",
    "ip-vrf": "Create an ip-vrf for tenant initech on leaf01 ethernet-1/1 and leaf02 "
              "ethernet-1/1 using VLAN 200, with prefixes 10.50.0.0/24 and 2001:db8:50::/64",
}
BOUND_S = 300.0
RETIRED = ("l2vpn", "l3vpn", "evpn-vpws", "vpls", "elan", "l2-service", "l3-service")


def assignments_dir() -> Path:
    base = Path(os.environ.get("EVIDENCE_DIR") or "/tmp/agentic-netops-e2e")  # noqa: S108
    path = base / "t103" / "assignments"
    path.mkdir(parents=True, exist_ok=True)
    return path


@pytest.mark.parametrize("construct", list(CONSTRUCTS))
def test_construct_converges_and_is_removed(construct: str) -> None:
    svc = provision(CONSTRUCTS[construct])
    assert svc.interpretation and svc.interpretation["service_type"] == construct
    assert svc.assignment and svc.assignment["type"] == construct
    assert svc.network == f"migr-{svc.assignment['serviceId']}"
    assert svc.approval_to_converged_s is not None
    assert svc.approval_to_converged_s <= BOUND_S, svc.approval_to_converged_s

    live = network(svc.network)
    assert live is not None
    ready = {c["type"]: c for c in live["status"]["conditions"]}["Ready"]
    assert ready["status"] == "True", ready
    labels = live["metadata"]["labels"]
    assert labels["agentic-netops.io/correlation-id"] == svc.correlation_id
    assert labels["agentic-netops.io/tier"] == "intent"
    assert "fabric.agentic-netops.io/finalizer" in live["metadata"].get("finalizers", [])
    annotations = live["metadata"]["annotations"]
    assert any(k.endswith("intent-submitted-spec-sha256") for k in annotations), annotations

    # construct vocabulary throughout — every operator-visible chunk names the construct and
    # never a retired service name (FR-026)
    text = "\n".join(t.text() for t in svc.turns).lower()
    assert construct in text
    for retired in RETIRED:
        assert f'"{retired}"' not in text, retired

    held = claims_of(svc.correlation_id)
    (assignments_dir() / f"{construct}.json").write_text(json.dumps({
        "assignment": svc.assignment, "network": svc.network,
        "correlation_id": svc.correlation_id, "live_spec": live["spec"]}, sort_keys=True))

    removal = remove(svc.network)
    final = removal[-1].last()
    statuses = [c.get("status") for t in removal for c in t.chunks]
    assert final.get("status") == "COMPLETED", removal[-1].text()
    assert "CONFIGURED" not in statuses and "VERIFIED" not in statuses
    assert network(svc.network) is None
    record(f"t103-construct-{construct}", {
        "construct": construct, "network": svc.network, "thread_id": svc.thread_id,
        "correlation_id": svc.correlation_id,
        "approval_to_converged_seconds": round(svc.approval_to_converged_s, 2),
        "bound_seconds": BOUND_S, "claims_while_live": sorted(c["metadata"]["name"]
                                                                for c in held),
        "claims_after_removal": sorted(c["metadata"]["name"]
                                       for c in claims_of(svc.correlation_id)),
        "removal_final": final})
