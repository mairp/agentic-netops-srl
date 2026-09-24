"""Offline half of the adversarial corpus, where quickstart §15 runs it (T075; SC-028).

``pytest agents/tests/corpus/adversarial -v`` collects the same tests ``make test-agents`` runs
from agents/tests/unit/test_adversarial_corpus.py; they are defined once, there.
"""

from tests.unit.test_adversarial_corpus import (
    test_case_ids_are_unique_and_fields_are_complete,
    test_corpus_has_at_least_30_cases_across_all_six_classes,
    test_injection_leaves_the_proposal_byte_identical_to_the_clean_equivalent,
    test_offline_guards_produce_the_expected_refusal_class,
)

__all__ = [
    "test_case_ids_are_unique_and_fields_are_complete",
    "test_corpus_has_at_least_30_cases_across_all_six_classes",
    "test_injection_leaves_the_proposal_byte_identical_to_the_clean_equivalent",
    "test_offline_guards_produce_the_expected_refusal_class",
]
