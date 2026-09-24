"""Agent cards of the three provisioning workers (T084; data-model.md §14, FR-071).

A card is the a2a-sdk ``AgentCard`` (validated by the pinned model) plus the routable ``id``
(``org/namespace/local_name``) the SLIM topic is derived from, and ``x-agentic-netops-worker``, the
short name health reports use. One skill per worker. The supervisor finds cards in the
``agent-cards`` ConfigMap at call time; the tracked copies under ``deploy/agents/cards/`` are the
output of ``python -m provisioning.<worker>.card`` byte for byte (a unit test asserts it).
"""

from __future__ import annotations

import json
from typing import Any

from a2a.types import AgentCapabilities, AgentCard, AgentSkill

VERSION = "0.1.0"
ORG_NAMESPACE = "devnet/provisioning"


def build_card(*, local_name: str, worker: str, name: str, description: str, skill_id: str,
               skill_name: str, skill_description: str, tags: list[str],
               examples: list[str]) -> dict[str, Any]:
    card_id = f"{ORG_NAMESPACE}/{local_name}"
    card = AgentCard(
        name=name,
        description=description,
        url=f"slim://{card_id}",
        preferred_transport="SLIM",
        version=VERSION,
        capabilities=AgentCapabilities(streaming=False, push_notifications=False),
        default_input_modes=["application/json", "text/plain"],
        default_output_modes=["application/json", "text/plain"],
        skills=[AgentSkill(id=skill_id, name=skill_name, description=skill_description,
                           tags=tags, examples=examples)],
    )
    body = card.model_dump(mode="json", by_alias=True, exclude_none=True)
    return {"id": card_id, "x-agentic-netops-worker": worker, **body}


def render(card: dict[str, Any]) -> str:
    """The card as its tracked file holds it."""
    return json.dumps(card, indent=2, sort_keys=True, ensure_ascii=False) + "\n"


def print_card(card: dict[str, Any]) -> None:
    import sys

    sys.stdout.write(render(card))
