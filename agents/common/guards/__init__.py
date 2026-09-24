"""Behavioural guards of the intent tier (T074; FR-050, FR-076, FR-077, FR-079).

Mounted by the supervisor in front of every model call (T085). Deterministic throughout: no guard
asks a model whether a request is safe.

* :mod:`.classifier` — provisionable / informational / unsupported-or-unsafe (FR-050, FR-076);
* :mod:`.refusals` — refusals naming the declarative equivalent in construct vocabulary (FR-076);
* :mod:`.injection` — operator and worker text carried as delimited data (FR-077);
* :mod:`.proposal` — the canonical proposal bytes the injection guarantee is asserted on (FR-077);
* :mod:`.redaction` — the FR-079 credential and secret pattern set.
"""

from common.guards.classifier import Classification, RequestClass, classify
from common.guards.injection import Finding, Prompt, build_prompt, neutralize, wrap_as_data
from common.guards.proposal import Proposal, build_proposal
from common.guards.redaction import (
    RedactingFilter,
    find_credentials,
    redact,
    redact_mapping,
    redact_transcript,
)
from common.guards.refusals import Refusal, RefusalClass

__all__ = [
    "Classification",
    "Finding",
    "Prompt",
    "Proposal",
    "RedactingFilter",
    "Refusal",
    "RefusalClass",
    "RequestClass",
    "build_prompt",
    "build_proposal",
    "classify",
    "find_credentials",
    "neutralize",
    "redact",
    "redact_mapping",
    "redact_transcript",
    "wrap_as_data",
]
