"""The deployer's agent card (T084; contracts/a2a-transport.md):
``python -m provisioning.deployer.card`` prints it; ``deploy/agents/cards/deployer.json`` is that
output."""

from __future__ import annotations

from typing import Any

from provisioning.cards import build_card, print_card

CARD_ID = "devnet/provisioning/network-deployer"
SKILL = "deploy-network-service"


def card() -> dict[str, Any]:
    return build_card(
        local_name="network-deployer",
        worker="deployer",
        name="Network deployer agent",
        description=(
            "Submits a twice-confirmed NormalizedServiceIntent as a Network in the intent "
            "namespace, or removes one, and watches it until it converges, is gone, or the "
            "convergence timeout names what it is waiting for."
        ),
        skill_id=SKILL,
        skill_name="Deploy a network service",
        skill_description=(
            "Creates or removes the Network of an approved assignment (idempotent on the thread) "
            "and reports progress with the Ready condition's status string and reason."
        ),
        tags=["intent", "deployment", "network"],
        examples=["Deploy the approved assignment of thread 3f2b…"],
    )


if __name__ == "__main__":
    print_card(card())
