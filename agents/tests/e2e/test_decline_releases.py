"""T103 — a decline at either confirmation leaves zero resources and zero claims
(quickstart.md §18; SC-026).

A ``mac-vrf`` naming no VLAN is used because it is the construct whose assignment claims the most
(an allocated VLAN and an L2VNI), so a decline at the second confirmation has real claims to
release. The before/after allocation diff is taken over the claims of this request's correlation
label and over the whole claim set restricted to names carrying the request's service identifier,
so a concurrent suite's claims cannot mask or fake the result.
"""

from __future__ import annotations

import pytest
from conftest import record
from tierflow import (
    ask,
    claim_snapshot,
    claims_of,
    confirm_interpretation,
    network,
    networks,
    request_to_confirmation,
)

PROMPT = ("Create a mac-vrf for tenant globex across leaf01 ethernet-1/1 and leaf02 "
          "ethernet-1/1 and allocate its VLAN")


def _mine(snapshot: set[str], service_id: str) -> set[str]:
    return {s for s in snapshot if service_id in s}


@pytest.mark.parametrize("point", ["confirmation-1", "confirmation-2"])
def test_decline_leaves_nothing(point: str) -> None:
    before_networks = set(networks())
    before_claims = claim_snapshot()
    svc = request_to_confirmation(PROMPT)
    sid = svc.interpretation["service_id"]
    held_before_decline: list[str] = []
    if point == "confirmation-2":
        confirm_interpretation(svc)
        assert svc.assignment and svc.assignment.get("l2vni"), svc.assignment
        held_before_decline = sorted(c["metadata"]["name"]
                                     for c in claims_of(svc.correlation_id))
        assert held_before_decline, "the assignment claimed nothing to release"
    turn = ask("no", svc.thread_id)
    final = turn.last()
    assert final.get("type") == "final", turn.text()
    assert "declin" in (final.get("message") or "").lower(), final
    after_claims = claim_snapshot()
    assert claims_of(svc.correlation_id) == []
    assert _mine(after_claims, sid) == set() == _mine(before_claims, sid)
    assert network(f"migr-{sid}") is None
    assert set(networks()) - before_networks == set()
    # the thread stays amendable: a further message on it is answered, not refused as closed
    again = ask("What constructs can I ask for?", svc.thread_id)
    assert again.last().get("type") == "final", again.text()
    record(f"t103-decline-{point}", {
        "point": point, "thread_id": svc.thread_id, "correlation_id": svc.correlation_id,
        "service_id": sid, "claims_held_before_decline": held_before_decline,
        "claims_after_decline": [], "networks_created": [], "final": final})
