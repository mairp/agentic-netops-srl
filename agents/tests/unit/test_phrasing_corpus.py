"""The phrasing and unsupported-construct corpora, offline half (T143; SC-020, SC-027).

Holds agents/tests/corpus/phrasings/cases.yaml and agents/tests/corpus/unsupported/cases.yaml to
their shape — parseable, unique ids, at least 20 phrasings across all four constructs (the gateway
and the acl-as-a-property shapes among them), VLANs in the naming band, every node and port in the
reference site's inventory, every construct and gated property qualified in the documented record
— and proves each label against the platform's deterministic code:

* every phrasing is classified provisionable by the guard (so it reaches the mapper), and its
  expected reading is a schema-valid Interpretation that the mapper's review, run against the
  input text, the reference site and the documented record, accepts unchanged — or, for a
  ``clarify`` case, answers with a question for the labelled field;
* every unsupported case is refused naming each expected property — by the guard's message, or by
  the mapper's review of the interpretation the model is expected to return.

It also unit-tests the live runner's pure scoring (agents/tests/corpus/run_corpus.py), which T144
runs against the lab.
"""

from __future__ import annotations

import json
from collections import Counter
from pathlib import Path
from typing import Any

import pytest

from common.guards.classifier import RequestClass, classify
from common.schemas.interpretation import Interpretation
from common.schemas.stream import build_chunk
from provisioning.mapper import catalogue as catalogue_mod
from provisioning.mapper.agent import Inventory, review, validate_model_output
from supervisors.provisioning.prompts import render
from tests.corpus import run_corpus as rc
from tests.unit.test_suggested_prompts import documented_record, site_inventory

PHRASINGS = rc.load_corpus(rc.CORPORA["phrasings"])
UNSUPPORTED = rc.load_corpus(rc.CORPORA["unsupported"])
CONSTRUCTS = ("vlan", "mac-vrf", "ip-vrf", "acl")
NAMING_BAND = range(100, 1000)
SERVICE_ID = "0123456789abcde"
CORR = "0" * 32


# --------------------------------------------------------------------------------------------------
# helpers: the reference site, a reading as the model's JSON, the mapper's review
# --------------------------------------------------------------------------------------------------


def _inventory() -> Inventory:
    return Inventory.from_dict({"nodes": [
        {"name": n, "role": v["role"], "accessPorts": v["accessPorts"]}
        for n, v in site_inventory().items()]})


def model_json(reading: dict[str, Any]) -> dict[str, Any]:
    """The Interpretation a model would return for ``reading`` (rule names and priorities, which a
    reading does not label unless the operator stated them, filled in)."""
    data: dict[str, Any] = {
        "service_id": SERVICE_ID,
        "service_type": reading["construct"],
        "tenant": reading["tenant"],
        "endpoints": [{"site_or_node": e["node"], "attachment": e["port"],
                       **({"vlan": e["vlan"]} if e.get("vlan") is not None else {})}
                      for e in reading["endpoints"]],
    }
    if "anycast_gateway" in reading:
        data["anycast_gateway"] = dict(reading["anycast_gateway"])
    for key in ("ipv4_prefixes", "ipv6_prefixes"):
        if reading.get(key):
            data[key] = list(reading[key])
    if "acl" in reading:
        acl = reading["acl"]
        rules = []
        for i, rule in enumerate(acl["rules"]):
            body = {"name": rule.get("name", f"rule-{i + 1}"),
                    "priority": rule.get("priority", 10 * (i + 1)), "action": rule["action"]}
            body.update({k: rule[k] for k in rc.MATCH_FIELDS if k in rule})
            rules.append(body)
        data["acl"] = {"stage": acl["stage"], "type": acl["type"], "rules": rules}
        if acl.get("default_action") is not None:
            data["acl"]["default_action"] = acl["default_action"]
    return data


def reviewed(case: dict[str, Any]) -> Interpretation:
    interp = validate_model_output(json.dumps(model_json(case["reading"])), SERVICE_ID)
    return review(interp, text=case["input"], inventory=_inventory(),
                  qualification=documented_record(), catalogue=catalogue_mod.load(None))


def _ids(cases: list[dict[str, Any]]) -> list[str]:
    return [c["id"] for c in cases]


# --------------------------------------------------------------------------------------------------
# the phrasing corpus
# --------------------------------------------------------------------------------------------------


def test_phrasing_corpus_shape() -> None:
    ids = _ids(PHRASINGS)
    assert len(ids) == len(set(ids)), [i for i, n in Counter(ids).items() if n > 1]
    assert len(PHRASINGS) >= rc.SC020_MIN_CASES
    for case in PHRASINGS:
        assert {"id", "style", "input", "expected", "reading"} <= set(case), case["id"]
        assert case["expected"] in ("interpret", "clarify"), case["id"]
        if case["expected"] == "clarify":
            assert case.get("clarify_field"), case["id"]
    interpret = [c for c in PHRASINGS if c["expected"] == "interpret"]
    assert len(interpret) >= rc.SC020_MIN_CASES
    assert {c["reading"]["construct"] for c in interpret} == set(CONSTRUCTS)
    # the property shapes: a gateway on a mac-vrf, an acl on another construct, a standalone acl
    assert any(c["reading"]["construct"] == "mac-vrf" and c["reading"].get("anycast_gateway")
               for c in interpret)
    assert any(c["reading"]["construct"] != "acl" and "acl" in c["reading"] for c in interpret)
    assert any(c["reading"]["construct"] == "acl" for c in interpret)
    assert len({c["style"] for c in PHRASINGS}) >= 5


@pytest.mark.parametrize("case", PHRASINGS + [c for c in UNSUPPORTED if "reading" in c],
                         ids=lambda c: c["id"])
def test_readings_name_only_the_reference_site_and_the_naming_band(case: dict[str, Any]) -> None:
    inventory = site_inventory()
    for ep in case["reading"]["endpoints"]:
        assert ep["node"] in inventory and inventory[ep["node"]]["role"] == "leaf", ep
        if ep["port"] != "unknown":
            assert ep["port"] in inventory[ep["node"]]["accessPorts"], ep
        if ep.get("vlan") is not None:
            assert ep["vlan"] in NAMING_BAND, ep
            assert str(ep["vlan"]) in case["input"], f"VLAN {ep['vlan']} not in the text"


@pytest.mark.parametrize("case", PHRASINGS, ids=lambda c: c["id"])
def test_every_phrasing_reaches_the_mapper(case: dict[str, Any]) -> None:
    verdict = classify(case["input"])
    assert verdict.request_class == RequestClass.PROVISIONABLE, (verdict, case["input"])
    assert not verdict.quarantined


@pytest.mark.parametrize("case", [c for c in PHRASINGS if c["expected"] == "interpret"],
                         ids=lambda c: c["id"])
def test_expected_reading_is_accepted_by_the_mapper_review(case: dict[str, Any]) -> None:
    interp = reviewed(case)
    assert interp.unsupported_properties == [], interp.unsupported_properties
    assert interp.missing_fields == [], interp.missing_fields
    record = documented_record()
    assert record.get(case["reading"]["construct"]) == "qualified"
    # the runner's comparison accepts the reviewed reading it labels (round trip)
    assert rc.reading_mismatches(case["reading"], interp.to_wire()) == []


@pytest.mark.parametrize("case", [c for c in PHRASINGS if c["expected"] == "clarify"],
                         ids=lambda c: c["id"])
def test_clarify_cases_are_answered_with_the_labelled_question(case: dict[str, Any]) -> None:
    interp = reviewed(case)
    assert interp.unsupported_properties == [], interp.unsupported_properties
    assert any(case["clarify_field"] in m for m in interp.missing_fields), interp.missing_fields


# --------------------------------------------------------------------------------------------------
# the unsupported corpus
# --------------------------------------------------------------------------------------------------


def test_unsupported_corpus_shape() -> None:
    ids = _ids(UNSUPPORTED)
    assert len(ids) == len(set(ids)), [i for i, n in Counter(ids).items() if n > 1]
    assert len(UNSUPPORTED) >= 10
    names = {c["name"] for c in catalogue_mod.load(None).raw["unsupported_claims"]}
    named = {p for c in UNSUPPORTED for p in c["expected_unsupported"]}
    # every catalogue claim a request can make is exercised, except raw device CLI, which the
    # adversarial corpus owns (it is a device action)
    assert names - {"raw device CLI"} <= named, names - named
    for case in UNSUPPORTED:
        assert case["path"] in ("guard", "mapper"), case["id"]
        assert case["expected_unsupported"], f"{case['id']} names no property"
        assert all(isinstance(p, str) and p for p in case["expected_unsupported"]), case["id"]
        if case["path"] == "mapper":
            assert "reading" in case, case["id"]


@pytest.mark.parametrize("case", UNSUPPORTED, ids=lambda c: c["id"])
def test_every_unsupported_case_is_refused_naming_its_properties(case: dict[str, Any]) -> None:
    verdict = classify(case["input"])
    if case["path"] == "guard":
        assert verdict.request_class == RequestClass.UNSUPPORTED_OR_UNSAFE, verdict
        said = verdict.refusal.message
    else:
        assert verdict.request_class == RequestClass.PROVISIONABLE, verdict
        interp = reviewed(case)
        assert interp.unsupported_properties, "the review refused nothing"
        assert interp.missing_fields == []
        said = "\n".join(interp.unsupported_properties)
    unnamed = [p for p in case["expected_unsupported"] if p.casefold() not in said.casefold()]
    assert not unnamed, f"{unnamed} not named in: {said}"


# --------------------------------------------------------------------------------------------------
# the runner: reading a turn
# --------------------------------------------------------------------------------------------------


def _line(**fields: Any) -> dict[str, Any]:
    return json.loads(build_chunk(correlation_id=CORR, thread_id="t-1", **fields).line())


def interpreted_turn(wire: dict[str, Any]) -> list[dict[str, Any]]:
    return [_line(type="status", status="VALIDATED", stage="supervisor"),
            _line(type="stage", status="MAPPED", stage="mapper", payload=wire),
            _line(type="confirmation_request", status="MAPPED", stage="mapper",
                  prompt="Confirm this vlan interpretation?")]


def clarify_turn(fields: str) -> list[dict[str, Any]]:
    return [_line(type="status", status="VALIDATED", stage="supervisor"),
            _line(type="final", status="RECEIVED_REQUEST",
                  message=render("clarification", fields=fields))]


def refused_turn(causes: list[str]) -> list[dict[str, Any]]:
    return [_line(type="error", status="FAILED", stage="mapper", reason="; ".join(causes)),
            _line(type="final", status="FAILED", message=render("refused",
                                                                causes="\n".join(causes)))]


CASE = next(c for c in PHRASINGS if c["id"] == "acl-01-canonical")


def test_outcome_of_each_turn_shape() -> None:
    wire = reviewed(CASE).to_wire()
    assert rc.outcome_of(interpreted_turn(wire)).kind == "interpreted"
    out = rc.outcome_of(clarify_turn("tenant, endpoints[0].attachment"))
    assert (out.kind, out.fields) == ("clarify", "tenant, endpoints[0].attachment")
    assert rc.outcome_of(refused_turn(["x: not supported"])).kind == "refused"
    assert rc.outcome_of([_line(type="final", status="COMPLETED", message="hi")]).kind == \
        "answered"
    assert rc.outcome_of([_line(type="error", status="FAILED", stage="mapper", reason="down",
                                retryable=True)]).kind == "error"


def test_classify_phrasing() -> None:
    wire = reviewed(CASE).to_wire()
    assert rc.classify_phrasing(CASE, interpreted_turn(wire))[0] == rc.CORRECT
    wrong = json.loads(json.dumps(wire))
    wrong["acl"]["rules"][0]["destination_port"] = "80"
    verdict, detail = rc.classify_phrasing(CASE, interpreted_turn(wrong))
    assert verdict == rc.WRONG and detail
    no_default = json.loads(json.dumps(wire))
    no_default["acl"].pop("default_action")
    assert rc.classify_phrasing(CASE, interpreted_turn(no_default))[0] == rc.WRONG
    # "deny everything else" as a catch-all rule after the permit is the same reading
    catch_all = json.loads(json.dumps(no_default))
    catch_all["acl"]["rules"].append({"name": "deny-rest", "priority": 100, "action": "deny"})
    assert rc.classify_phrasing(CASE, interpreted_turn(catch_all))[0] == rc.CORRECT
    catch_all["acl"]["rules"][-1]["priority"] = 1  # ahead of the permit: a different filter
    assert rc.classify_phrasing(CASE, interpreted_turn(catch_all))[0] == rc.WRONG
    assert rc.classify_phrasing(CASE, clarify_turn("tenant"))[0] == rc.CLARIFY
    assert rc.classify_phrasing(CASE, refused_turn(["no"]))[0] == rc.WRONG
    assert rc.classify_phrasing(CASE, interpreted_turn(wire), ["Network/x"])[0] == rc.WRONG
    clar = next(c for c in PHRASINGS if c["id"] == "clarify-01-no-tenant")
    assert rc.classify_phrasing(clar, clarify_turn("tenant"))[0] == rc.CORRECT
    assert rc.classify_phrasing(clar, clarify_turn("endpoints[0].vlan"))[0] == rc.CLARIFY
    assert rc.classify_phrasing(clar, interpreted_turn(wire))[0] == rc.WRONG


def test_classify_unsupported() -> None:
    case = next(c for c in UNSUPPORTED if c["id"] == "mapper-04-macvrf-pw-oam-control-word")
    causes = reviewed(case).unsupported_properties
    assert rc.classify_unsupported(case, refused_turn(causes))[0] == rc.REFUSED
    missing = [c for c in causes if "control word" not in c.lower()]
    verdict, detail = rc.classify_unsupported(case, refused_turn(missing))
    assert verdict == rc.WRONG and "control word" in detail[0]
    assert rc.classify_unsupported(case, refused_turn(causes), [], ["claim/x"])[0] == rc.WRONG
    wire = reviewed(CASE).to_wire()
    assert rc.classify_unsupported(case, interpreted_turn(wire))[0] == rc.WRONG
    guard = next(c for c in UNSUPPORTED if c["path"] == "guard")
    message = classify(guard["input"]).refusal.message
    turn = [_line(type="final", status="FAILED", message=message)]
    assert rc.classify_unsupported(guard, turn)[0] == rc.REFUSED


# --------------------------------------------------------------------------------------------------
# the runner: scoring
# --------------------------------------------------------------------------------------------------


def test_sc020_passes_at_90_percent_with_every_other_case_a_question() -> None:
    assert rc.score_phrasings([rc.CORRECT] * 18 + [rc.CLARIFY] * 2).passed
    assert rc.score_phrasings([rc.CORRECT] * 20).passed
    assert rc.score_phrasings([rc.CORRECT] * 27 + [rc.CLARIFY] * 3).passed


def test_sc020_fails_on_a_single_wrong_reading() -> None:
    score = rc.score_phrasings([rc.CORRECT] * 18 + [rc.CLARIFY, rc.WRONG])
    assert not score.passed and "neither correct nor" in score.reasons[0]
    assert not rc.score_phrasings([rc.CORRECT] * 19 + [rc.ERROR]).passed


def test_sc020_fails_below_90_percent_even_when_the_rest_are_questions() -> None:
    score = rc.score_phrasings([rc.CORRECT] * 17 + [rc.CLARIFY] * 3)
    assert not score.passed and "below 90%" in score.reasons[0]


def test_sc020_fails_on_fewer_than_20_cases() -> None:
    assert not rc.score_phrasings([rc.CORRECT] * 19).passed


def test_sc027_every_case_must_be_refused_cleanly() -> None:
    assert rc.score_unsupported([rc.REFUSED] * 14).passed
    assert not rc.score_unsupported([rc.REFUSED] * 13 + [rc.WRONG]).passed
    assert not rc.score_unsupported([]).passed


def test_the_runner_negative_control_fails_what_it_must() -> None:
    assert rc.negative_control() == []


def test_provider_fields_never_include_the_key() -> None:
    source = Path(rc.__file__).read_text(encoding="utf-8")
    assert "API_KEY" not in source
