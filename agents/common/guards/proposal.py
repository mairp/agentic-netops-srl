"""The guard layer's deterministic proposal and its canonical bytes (T074; FR-077, SC-028).

A proposal is what the guard layer passes downstream for one request: its classification, the
fields it can read deterministically, and the operator and worker text as neutralized, redacted
data. Quarantined instructions are carried beside it as findings — reported, never part of the
bytes — so a request with an embedded instruction yields a proposal **byte-identical** to the same
request without it, which is what FR-077 and the injection class of the adversarial corpus
(T075, T145) assert by comparing :meth:`Proposal.canonical_bytes` and :attr:`Proposal.sha256`.
"""

from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass
from typing import Any

from common.guards.classifier import _classify_kept, extract_fields
from common.guards.injection import Finding, neutralize
from common.guards.redaction import redact

PROPOSAL_VERSION = "agentic-netops.io/guard-proposal/v1"


@dataclass(frozen=True)
class Proposal:
    body: dict[str, Any]
    quarantined: tuple[Finding, ...]

    def canonical_bytes(self) -> bytes:
        """Sorted keys, no insignificant whitespace, UTF-8: one byte string per proposal."""
        return json.dumps(
            self.body, sort_keys=True, separators=(",", ":"), ensure_ascii=False
        ).encode("utf-8")

    @property
    def sha256(self) -> str:
        return hashlib.sha256(self.canonical_bytes()).hexdigest()


def build_proposal(
    operator_text: str, worker_text: str | None = None, *, worker: str = "mapper"
) -> Proposal:
    """Build the proposal for one request and, optionally, one worker's returned text."""
    kept, findings = neutralize(operator_text, "operator")
    request_class, refusal, construct = _classify_kept(kept)
    fields = extract_fields(kept) if construct is not None else {}
    body: dict[str, Any] = {
        "version": PROPOSAL_VERSION,
        "classification": str(request_class),
        "refusal": str(refusal.refusal_class) if refusal else None,
        "construct": construct,
        "fields": fields,
        "operator_text": redact(kept),
        "worker_text": None,
    }
    quarantined = list(findings)
    if worker_text is not None:
        kept_worker, worker_findings = neutralize(worker_text, f"worker:{worker}")
        quarantined.extend(worker_findings)
        body["worker_text"] = {"worker": worker, "text": redact(kept_worker)}
    return Proposal(body=body, quarantined=tuple(quarantined))
