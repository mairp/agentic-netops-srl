"""The mapper's agent card (T084; contracts/a2a-transport.md):
``python -m provisioning.mapper.card`` prints it; ``deploy/agents/cards/mapper.json`` is that
output."""

from __future__ import annotations

from typing import Any

from provisioning.cards import build_card, print_card

CARD_ID = "devnet/provisioning/network-mapping"
SKILL = "map-network-request"


def card() -> dict[str, Any]:
    return build_card(
        local_name="network-mapping",
        worker="mapper",
        name="Network mapping agent",
        description=(
            "Maps an operator's natural-language network request onto the datacenter construct "
            "vocabulary (vlan, mac-vrf, ip-vrf, acl) as an Interpretation, resolved against the "
            "site inventory and the fabric qualification record."
        ),
        skill_id=SKILL,
        skill_name="Map a network request",
        skill_description=(
            "Produces an Interpretation (contracts/interpretation.schema.json) from a request: "
            "the construct, the tenant, the endpoints in the device's own naming, and any "
            "missing fields or unsupported properties."
        ),
        tags=["intent", "mapping", "construct-vocabulary"],
        examples=["Extend vlan 100 as a mac-vrf across leaf01 ethernet-1/1 and leaf02 "
                  "ethernet-1/1 for tenant blue"],
    )


if __name__ == "__main__":
    print_card(card())
