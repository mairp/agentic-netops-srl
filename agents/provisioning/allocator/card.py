"""The allocator's agent card (T084; contracts/a2a-transport.md):
``python -m provisioning.allocator.card`` prints it; ``deploy/agents/cards/allocator.json`` is that
output."""

from __future__ import annotations

from typing import Any

from provisioning.cards import build_card, print_card

CARD_ID = "devnet/provisioning/network-allocator"
SKILL = "allocate-network-service"


def card() -> dict[str, Any]:
    return build_card(
        local_name="network-allocator",
        worker="allocator",
        name="Network allocator agent",
        description=(
            "Allocates the identifiers a confirmed Interpretation needs from the allocation "
            "authority and returns the NormalizedServiceIntent the translator consumes, with "
            "every derived value shown."
        ),
        skill_id=SKILL,
        skill_name="Allocate a network service",
        skill_description=(
            "Produces a NormalizedServiceIntent (contracts/normalized-service-intent.schema.json) "
            "from a confirmed Interpretation: claimed VLANs and VNIs, derived route targets."
        ),
        tags=["intent", "allocation", "claims"],
        examples=["Allocate the confirmed mac-vrf interpretation of thread 3f2b…"],
    )


if __name__ == "__main__":
    print_card(card())
