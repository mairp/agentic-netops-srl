"""The adversarial corpus, offline half (T075; SC-028, FR-076, FR-077).

Loads agents/tests/corpus/adversarial/cases.yaml, asserts its shape — at least 30 cases, all six
classes present with at least five each, unique ids — and runs every case through the offline
guards of T074: each must produce its expected refusal class, a device-action refusal must name
its expected declarative equivalent, and for both injection classes the proposal must be
byte-identical to the proposal of the case's clean equivalent. The live run through the tier,
with zero device sessions per source, is T145.

Also collected by ``pytest agents/tests/corpus/adversarial`` (quickstart §15) through
agents/tests/corpus/adversarial/test_corpus_offline.py.
"""

from __future__ import annotations

from collections import Counter
from pathlib import Path
from typing import Any

import pytest
import yaml

from common.guards import RefusalClass, build_proposal, classify

CORPUS = Path(__file__).resolve().parents[1] / "corpus" / "adversarial" / "cases.yaml"

CLASSES = {
    "direct-device-command": RefusalClass.UNSUPPORTED_OR_UNSAFE,
    "shell-cli-request": RefusalClass.UNSUPPORTED_OR_UNSAFE,
    "injection-operator-text": RefusalClass.INJECTION_QUARANTINED,
    "injection-worker-output": RefusalClass.INJECTION_QUARANTINED,
    "confirmation-bypass": RefusalClass.CONFIRMATION_REQUIRED,
    "tool-name-confusion": RefusalClass.UNKNOWN_TOOL,
}


def _load() -> list[dict[str, Any]]:
    return yaml.safe_load(CORPUS.read_text(encoding="utf-8"))["cases"]


CASES = _load()


def test_corpus_has_at_least_30_cases_across_all_six_classes() -> None:
    assert len(CASES) >= 30
    counts = Counter(case["class"] for case in CASES)
    assert set(counts) == set(CLASSES), f"classes present: {sorted(counts)}"
    thin = {name: n for name, n in counts.items() if n < 5}
    assert not thin, f"classes with fewer than five cases: {thin}"


def test_case_ids_are_unique_and_fields_are_complete() -> None:
    ids = [case["id"] for case in CASES]
    assert len(ids) == len(set(ids)), [i for i, n in Counter(ids).items() if n > 1]
    for case in CASES:
        assert {"id", "class", "input", "expected_refusal_class"} <= set(case), case["id"]
        assert case["class"] in CLASSES, case["id"]
        assert case["expected_refusal_class"] == CLASSES[case["class"]], case["id"]
        if case["class"].startswith("injection-"):
            assert case.get("clean_equivalent"), f"{case['id']}: no clean_equivalent"
        if case["class"] == "injection-worker-output":
            assert case.get("worker_output"), f"{case['id']}: no worker_output"


def _offline_refusal_class(case: dict[str, Any]) -> RefusalClass | None:
    result = classify(case["input"])
    if case["class"] == "injection-worker-output":
        if result.refusal_class is not None:
            return result.refusal_class
        proposal = build_proposal(case["input"], case["worker_output"], worker=case["worker"])
        return RefusalClass.INJECTION_QUARANTINED if proposal.quarantined else None
    return result.refusal_class


@pytest.mark.parametrize("case", CASES, ids=[c["id"] for c in CASES])
def test_offline_guards_produce_the_expected_refusal_class(case: dict[str, Any]) -> None:
    assert _offline_refusal_class(case) == case["expected_refusal_class"], case["input"]

    result = classify(case["input"])
    if result.refusal is not None:
        message = result.refusal.message
        assert "a Network submitted through the intent tier" in message, case["id"]
        if "expected_equivalent" in case:
            assert result.refusal.equivalent == case["expected_equivalent"], case["id"]
            assert f"declare a {case['expected_equivalent']}" in message, case["id"]


@pytest.mark.parametrize(
    "case",
    [c for c in CASES if c["class"].startswith("injection-")],
    ids=[c["id"] for c in CASES if c["class"].startswith("injection-")],
)
def test_injection_leaves_the_proposal_byte_identical_to_the_clean_equivalent(
    case: dict[str, Any],
) -> None:
    if case["class"] == "injection-operator-text":
        dirty = build_proposal(case["input"])
        clean = build_proposal(case["clean_equivalent"])
    else:
        dirty = build_proposal(case["input"], case["worker_output"], worker=case["worker"])
        clean = build_proposal(case["input"], case["clean_equivalent"], worker=case["worker"])
    assert dirty.canonical_bytes() == clean.canonical_bytes(), case["id"]
    assert dirty.sha256 == clean.sha256, case["id"]
    assert dirty.quarantined and not clean.quarantined, case["id"]
    # The request under the injection is still the request: never refused for what it carried.
    assert clean.body["classification"] == "provisionable", case["id"]
