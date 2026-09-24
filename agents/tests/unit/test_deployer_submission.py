"""T092 — the deployer's submission contract (contracts/kubernetes-objects.md §"Submission
contract" and §"Resource stamping contract"; contracts/supervisor-http.md; data-model.md §15 §17
§25; FR-055, FR-062, FR-064…FR-069, FR-101, FR-103, FR-109, CR-004, R-21, AD-32, AD-33, AD-40,
AD-52, AD-53, AD-62, AD-63).

Every test runs the real deployer stage against the fake API server, the fake translator sidecar
and a fake clock (tests/unit/deployer_fakes.py).
"""

from __future__ import annotations

import copy
import hashlib
import json
from typing import Any

import pytest
from a2a.types import DataPart

from common import metrics
from common.schemas.stream import DeploymentReport
from provisioning.deployer.stamp import SERVER_METADATA, SPEC_HASH_ANNOTATION
from provisioning.deployer.submit import ALLOCATION_VLAN_BAND, NAMING_VLAN_BAND
from tests.unit.conftest import span_events
from tests.unit.deployer_fakes import (
    ASSIGNMENT,
    CID,
    CONFIRM,
    NETWORK,
    NS,
    OTHER_CID,
    SERVICES_NS,
    SID,
    TRANSLATOR_ANNOTATIONS,
    Rig,
    condition,
    network_manifest,
)

pytestmark = pytest.mark.usefixtures("fresh_telemetry")

TIER_LABELS = ["agentic-netops.io/correlation-id", "agentic-netops.io/tier"]
TIER_ANNOTATIONS = ["agentic-netops.io/intent-thread-id", "agentic-netops.io/intent-principal",
                    "agentic-netops.io/intent-submitted-at"]
SECOND = f"migr-{SID}-b"


def _two_object_bundle(rig: Rig) -> None:
    second = network_manifest(SID, vlan=130, name=SECOND)
    for a in second["spec"]["attachments"]:
        a["attachment"] = "ethernet-1/2"
    rig.translator.extra = [second]


def _assert_ready_strings(report: DeploymentReport, raw: dict[str, Any] | None = None) -> None:
    for event in report.progress:
        assert not isinstance(event.ready, bool)
        assert isinstance(event.ready, str) and event.ready in ("True", "False", "Unknown")
        if event.ready in ("False", "Unknown"):
            assert event.reason, event
    for entry in (raw or {}).get("progress", []):
        assert type(entry["ready"]) is str, entry


# --------------------------------------------------------------------------------------------------
# the transaction's order, stamping, dry-run gate, apply and rollback
# --------------------------------------------------------------------------------------------------


async def test_order_is_preflight_translate_stamp_dry_run_apply_watch() -> None:
    rig = Rig()
    rig.converge_at(10)
    report = await rig.create()
    assert report.status == "COMPLETED"
    steps = [e for e in rig.log if not (e[0] == "api" and e[2] == "events")]
    assert steps[:5] == [
        ("api", "GET", NETWORK, ""),        # resumption check (is it already ours?)
        ("api", "GET", "networks", ""),     # 1. pre-flight: the intent namespace's Networks
        ("translate",),                     # 2. translate
        ("api", "PATCH", NETWORK, "All"),   # 4. dry-run (3. stamp is in its body)
        ("api", "PATCH", NETWORK, ""),      # 5. apply
    ]
    assert all(e == ("api", "GET", NETWORK, "") for e in steps[5:])  # 7. the watch polls
    (dry,) = rig.api.calls("PATCH", dry_run=True)
    assert dry["body"]["metadata"]["labels"]["agentic-netops.io/correlation-id"] == CID


async def test_stamp_translator_keys_first_tier_keys_second_disjoint_and_hash_last() -> None:
    rig = Rig()
    rig.converge_at(5)
    await rig.create()
    (dry,) = rig.api.calls("PATCH", dry_run=True)
    (applied,) = rig.api.calls("PATCH", dry_run=False)
    meta = dry["body"]["metadata"]
    assert meta["namespace"] == NS
    assert list(meta["labels"]) == TIER_LABELS
    assert meta["labels"] == {"agentic-netops.io/correlation-id": CID,
                              "agentic-netops.io/tier": "intent"}
    translator = list(TRANSLATOR_ANNOTATIONS)
    assert list(meta["annotations"]) == translator + TIER_ANNOTATIONS
    assert set(translator).isdisjoint([*TIER_ANNOTATIONS, SPEC_HASH_ANNOTATION])
    assert meta["annotations"]["agentic-netops.io/intent-principal"] == "alice"
    assert meta["annotations"]["agentic-netops.io/intent-submitted-at"] == "2026-09-24T12:00:00Z"
    assert SPEC_HASH_ANNOTATION not in meta["annotations"]  # not before the dry-run
    assert list(applied["body"]["metadata"]["annotations"])[-1] == SPEC_HASH_ANNOTATION


async def test_a_translator_writing_a_tier_key_is_refused_before_any_dry_run() -> None:
    rig = Rig()
    original = rig.translator.handle

    def handle(request: Any) -> Any:
        response = original(request)
        body = response.json()
        body["manifests"][0]["metadata"]["annotations"][
            "agentic-netops.io/intent-principal"] = "mallory"
        return type(response)(200, json=body)

    rig.translator.handle = handle  # type: ignore[method-assign]
    rig.deployer.translator_transport = rig.translator.transport
    report = await rig.create()
    assert report.status == "FAILED" and not report.submitted
    assert "disjoint" in (report.message or "")
    assert rig.api.calls("PATCH") == []


async def test_any_dry_run_rejection_aborts_the_whole_bundle_naming_the_object() -> None:
    rig = Rig()
    _two_object_bundle(rig)
    rig.api.reject[SECOND] = "spec.bridgeDomains[0].l2vni: Invalid value: 70000"
    report = await rig.create()
    assert report.status == "FAILED" and report.submitted is False
    assert f"Network/{SECOND}" in (report.message or "")
    assert "aborted" in (report.message or "")
    assert rig.api.network_writes() == []  # nothing mutated, nothing to roll back
    assert rig.api.networks == {}


async def test_a_rejection_on_the_second_apply_deletes_the_first_and_reports_the_set() -> None:
    rig = Rig()
    _two_object_bundle(rig)
    rig.api.reject_apply[SECOND] = "the object changed under the apply"
    report = await rig.create()
    assert report.status == "FAILED"
    assert report.rolled_back == [f"Network/{NETWORK}"]
    assert not report.survivors
    deletes = rig.api.calls("DELETE")
    assert [d["path"].rsplit("/", 1)[-1] for d in deletes] == [NETWORK]
    assert "rolled back" in (report.message or "") and f"Network/{NETWORK}" in report.message
    # finalizer-bound: the deletion blocks until the provider releases what it adopted, and the
    # release gate keeps refusing the id while the object exists — the rollback frees no claim.
    assert rig.api.networks[NETWORK]["metadata"]["deletionTimestamp"]
    gate = await rig.gate(CID)
    assert gate.releasable == [] and gate.refused[0].network == f"Network/{NETWORK}"


async def test_a_failed_rollback_is_reported_failed_naming_the_survivors() -> None:
    rig = Rig()
    _two_object_bundle(rig)
    rig.api.reject_apply[SECOND] = "the object changed under the apply"
    rig.api.delete_refused.add(NETWORK)
    report = await rig.create()
    assert report.status == "FAILED"
    assert report.survivors and f"Network/{NETWORK}" in report.survivors[0]
    assert "ROLLBACK FAILED" in (report.message or "")
    assert report.rolled_back == []


async def test_no_submission_without_the_second_confirmation() -> None:
    for confirmation in (None, {"decided": "decline", "principal": "alice"}, {}):
        rig = Rig()
        payload: dict[str, Any] = {"operation": "create", "assignment": {"serviceId": SID},
                                   "principal": "alice"}
        if confirmation is not None:
            payload["confirmation_2"] = confirmation
        report = await rig.call(payload)
        assert report.status == "FAILED" and report.submitted is False
        assert "second confirmation" in (report.message or "")
        assert rig.api.requests == [] and rig.translator.calls == []


async def test_the_applied_network_differs_from_its_dry_run_only_in_the_hash_annotation() -> None:
    rig = Rig()
    rig.converge_at(5)
    await rig.create()
    (dry,) = rig.api.calls("PATCH", dry_run=True)
    (applied,) = rig.api.calls("PATCH", dry_run=False)
    # What the dry-run returned: re-run it against the fake server's admission and defaulting.
    dry_result = rig.api._apply(NETWORK, copy.deepcopy(dry["body"]), dry_run=True).json()
    for body in (dry_result,):
        body.pop("status", None)
        for key in SERVER_METADATA:
            body["metadata"].pop(key, None)
    sent = copy.deepcopy(applied["body"])
    digest = sent["metadata"]["annotations"].pop(SPEC_HASH_ANNOTATION)
    assert sent == dry_result
    # the hash is the canonical JSON of the spec as the dry-run returned it (defaulted field in)
    assert "defaulted" in dry_result["spec"]["description"]
    canonical = json.dumps(dry_result["spec"], sort_keys=True, separators=(",", ":"),
                           ensure_ascii=False).encode()
    assert digest == hashlib.sha256(canonical).hexdigest()
    assert rig.api.networks[NETWORK]["metadata"]["annotations"][SPEC_HASH_ANNOTATION] == digest


async def test_apply_sets_the_finalizer_on_every_network_and_an_early_deletion_blocks() -> None:
    rig = Rig()
    _two_object_bundle(rig)
    rig.api.provider_marks_deleting = False  # the provider has not reconciled anything yet
    rig.clock.at(1, lambda: rig.api._delete(SECOND))  # deleted before any reconcile
    rig.converge_at(1000)  # never within the bound
    report = await rig.create()
    for call in rig.api.calls("PATCH"):
        assert call["body"]["metadata"]["finalizers"] == ["fabric.agentic-netops.io/finalizer"]
    assert SECOND in rig.api.networks  # blocked by the finalizer, not removed
    assert rig.api.networks[SECOND]["metadata"]["deletionTimestamp"]
    assert report.status == "FAILED"


# --------------------------------------------------------------------------------------------------
# the watch: three outcomes, Ready=Unknown none of them, the status string on every chunk
# --------------------------------------------------------------------------------------------------


async def test_watch_reports_ready() -> None:
    rig = Rig()
    rig.clock.at(5, lambda: rig.api.set_ready(NETWORK, "False", "NotConverged",
                                              "targets not Ready: leaf02"))
    rig.converge_at(30)
    report = await rig.create()
    assert report.status == "COMPLETED"
    assert [(p.status, p.ready, p.reason) for p in report.progress] == [
        ("PROVISIONING", "False", "NotConverged"), ("VERIFIED", "True", "Converged")]
    _assert_ready_strings(report)


async def test_watch_reports_a_terminal_failure() -> None:
    rig = Rig()
    rig.clock.at(5, lambda: rig.api.set_conditions(
        NETWORK, condition("Accepted", "False", "AllocationConflict",
                           "l2vni 10021 is held by another owner"),
        condition("Ready", "False", "NotConverged", "refused: l2vni 10021 is held")))
    report = await rig.create()
    assert report.status == "FAILED"
    assert "terminal" in (report.message or "") and "AllocationConflict" in report.message
    assert rig.clock.now < 150


async def test_watch_reports_the_convergence_timeout() -> None:
    rig = Rig()
    rig.clock.at(5, lambda: rig.api.set_ready(NETWORK, "False", "NotConverged",
                                              "targets not Ready: leaf02"))
    report = await rig.create()
    assert report.status == "FAILED"
    assert "convergence timeout" in (report.message or "") and "150 s" in report.message
    assert "leaf02" in report.message
    assert rig.clock.now == pytest.approx(150)


async def test_ready_unknown_is_none_of_the_three_and_keeps_the_watch_open() -> None:
    rig = Rig()
    rig.clock.at(5, lambda: rig.api.set_ready(NETWORK, "Unknown", "VerificationFailed",
                                              "read-back of leaf02 could not run"))
    rig.converge_at(60)
    report = await rig.create()
    assert rig.clock.now >= 60  # still watching past the Unknown
    assert [(p.ready, p.reason) for p in report.progress] == [
        ("Unknown", "VerificationFailed"), ("True", "Converged")]
    assert report.status == "COMPLETED"


async def test_a_status_request_on_ready_unknown_says_unknown_naming_the_target() -> None:
    rig = Rig()
    rig.converge_at(5)
    await rig.create()
    rig.api.set_ready(NETWORK, "Unknown", "VerificationFailed",
                      "the read-back of leaf02 could not run: target unreachable")
    report = await rig.status()
    assert report.state == "unknown"
    text = (report.message or "").lower()
    assert "unknown" in text and "leaf02" in text
    assert "converged" not in text and "failed" not in text.replace("verificationfailed", "")
    assert report.progress[0].ready == "Unknown" and report.progress[0].status != "VERIFIED"


async def test_a_status_request_on_ready_false_deleting_says_being_removed() -> None:
    rig = Rig()
    rig.converge_at(5)
    await rig.create()
    rig.api._delete(NETWORK)
    rig.api.set_conditions(NETWORK, condition(
        "Deleting", "True", "TargetUnreachable",
        "configuration removed from every reachable target; unreachable: leaf02"))
    report = await rig.status(tier_removed=True)
    assert report.state == "removing"
    assert "being removed" in (report.message or "") and "leaf02" in report.message
    assert "failed" not in report.message.lower() and "converged" not in report.message.lower()


async def test_every_progress_ready_is_a_status_string_with_its_reason() -> None:
    rig = Rig()
    rig.clock.at(5, lambda: rig.api.set_ready(NETWORK, "False", "NotConverged", "leaf02"))
    rig.clock.at(10, lambda: rig.api.set_ready(NETWORK, "Unknown", "VerificationFailed",
                                               "leaf02"))
    rig.converge_at(20)
    raw = await rig.raw({"operation": "create", "assignment": copy.deepcopy(ASSIGNMENT),
                         "principal": "alice", "confirmation_2": CONFIRM})
    (data,) = [p.root.data for p in raw.parts if isinstance(p.root, DataPart)]
    report = DeploymentReport.parse(data)
    assert [p.ready for p in report.progress] == ["False", "Unknown", "True"]
    _assert_ready_strings(report, data)
    rig.api.set_conditions(NETWORK, condition("Deleting", "True", "RemovingConfiguration", "x"))
    removal = await rig.remove()
    _assert_ready_strings(removal)
    assert removal.progress and all(p.ready == "False" and p.reason == "Deleting"
                                    for p in removal.progress)
    with pytest.raises(ValueError):
        DeploymentReport.parse({"status": "PROVISIONING", "progress": [
            {"status": "PROVISIONING", "resource": "Network/x", "ready": False}]})


async def test_a_creation_watch_seeing_deleting_fails_as_deleted_outside_the_tier(
        fresh_telemetry: Any) -> None:
    rig = Rig()
    before = metrics.value(metrics.OUT_OF_BAND_CHANGES, change="deleted")
    rig.clock.at(10, lambda: rig.api._delete(NETWORK))  # someone else deletes it
    report = await rig.create()
    assert report.status == "FAILED" and report.out_of_band == "deleted"
    assert "deleted" in (report.message or "") and "outside the intent tier" in report.message
    assert report.progress[-1].ready == "False" and report.progress[-1].reason == "Deleting"
    assert metrics.value(metrics.OUT_OF_BAND_CHANGES, change="deleted") == before + 1
    events = [a for n, a in span_events(fresh_telemetry) if n == "audit.out_of_band"]
    assert len(events) == 1 and events[0]["audit.reason"] == "deleted"
    assert events[0]["audit.principal"] == "alice"
    assert [e["reason"] for e in rig.api.events] == ["IntentSubmitted", "OutOfBandChange"]


# --------------------------------------------------------------------------------------------------
# the removal's two endings (FR-069, AD-63)
# --------------------------------------------------------------------------------------------------


async def _converged(rig: Rig) -> None:
    rig.converge_at(rig.clock.now + 5)
    assert (await rig.create()).status == "COMPLETED"


async def test_removal_a_gone_within_the_timeout_is_completed() -> None:
    rig = Rig()
    await _converged(rig)
    start = rig.clock.now
    rig.clock.at(start + 20, lambda: rig.api.finalize(NETWORK))
    report = await rig.remove()
    assert [(p.status, p.ready, p.reason) for p in report.progress] == [
        ("PROVISIONING", "False", "Deleting")]
    assert report.status == "COMPLETED" and report.operation == "remove"
    assert all(p.status not in ("CONFIGURED", "VERIFIED") for p in report.progress)
    assert NETWORK not in rig.api.networks  # COMPLETED only once the object was observed gone
    last_get = [r for r in rig.api.requests if r["method"] == "GET"][-1]
    assert last_get["path"].endswith(NETWORK)
    assert len(rig.api.calls("DELETE")) == 1
    assert rig.api.calls("POST") == []  # no claim, no object created


async def test_removal_b_held_by_an_unreachable_leaf_ends_in_progress_naming_it() -> None:
    rig = Rig()
    await _converged(rig)
    rig.clock.at(rig.clock.now + 5, lambda: rig.api.set_conditions(NETWORK, condition(
        "Deleting", "True", "TargetUnreachable",
        "configuration removed from every reachable target; unreachable: leaf02; every "
        "allocation stays claimed until the removal is read back from each")))
    writes_before = len(rig.api.network_writes())
    report = await rig.remove()
    assert report.status == "PROVISIONING"
    assert report.status not in ("COMPLETED", "FAILED", "STATUS_UNKNOWN")
    assert "removal in progress" in (report.message or "") and "leaf02" in report.message
    assert "waiting on leaf02 (TargetUnreachable)" in report.message
    assert all(p.status == "PROVISIONING" for p in report.progress)
    writes = rig.api.network_writes()[writes_before:]
    assert [w["method"] for w in writes] == ["DELETE"]  # one delete, no annotation write
    assert "force-release" not in json.dumps(rig.api.requests)
    # asked again: no second delete, and a status request answers "being removed"
    await rig.remove()
    assert len(rig.api.calls("DELETE")) == 1
    status = await rig.status(tier_removed=True)
    assert status.state == "removing" and "being removed" in (status.message or "")
    assert "leaf02" in status.message


# --------------------------------------------------------------------------------------------------
# the admission webhook unreachable is a dependency failure, not a refusal (AD-52, NFR-010)
# --------------------------------------------------------------------------------------------------


async def test_webhook_unreachable_dry_run_is_the_cluster_api_dependency_not_a_refusal() -> None:
    rig = Rig()
    rig.api.webhook_down = 3  # every attempt of the retry rule
    report = await rig.create()
    assert report.status == "FAILED" and report.retryable is True
    assert report.submitted is False
    assert report.dependency and "cluster API" in report.dependency
    assert "admission webhook" in report.dependency
    message = report.message or ""
    assert "cluster API dependency unavailable" in message and "admission webhook" in message
    assert not message.startswith("refused") and not report.causes  # never a refusal
    assert "valid names" not in message and "one of" not in message  # no list of valid names
    assert "nothing was applied" in message and "resumed" in message
    assert len(rig.api.calls("PATCH", dry_run=True)) == 3  # 1 + WORKER_CALL_RETRIES (2)
    assert rig.clock.sleeps == [1.0, 2.0]  # backoff from 1 s
    assert rig.api.network_writes() == [] and rig.api.calls("DELETE") == []
    gate = await rig.gate(CID)  # the claims are still provisional
    assert gate.releasable == [CID] and gate.refused == []


async def test_webhook_back_within_the_retry_rule_submits() -> None:
    rig = Rig()
    rig.api.webhook_down = 2
    rig.converge_at(10)
    report = await rig.create()
    assert report.status == "COMPLETED"
    assert len(rig.api.calls("PATCH", dry_run=True)) == 3


# --------------------------------------------------------------------------------------------------
# the release gate, the services-namespace holder, the pre-flight, the VLAN bands
# --------------------------------------------------------------------------------------------------


async def test_the_release_gate_refuses_an_id_whose_network_exists_naming_it() -> None:
    rig = Rig()
    await _converged(rig)
    gate = await rig.gate(CID, OTHER_CID)
    assert gate.operation == "release_gate" and gate.status == "COMPLETED"
    assert gate.releasable == [OTHER_CID]  # never reached apply: every claim releasable
    assert [(r.correlation_id, r.network) for r in gate.refused] == [
        (CID, f"Network/{NETWORK}")]
    assert rig.api.network_writes()[-1]["method"] == "PATCH"  # the gate itself wrote nothing


async def test_a_holder_in_the_services_namespace_is_refused_by_the_dry_run() -> None:
    rig = Rig()
    rig.api.services.append({"metadata": {"name": "lab-macvrf", "namespace": SERVICES_NS},
                             "spec": {"attachments": [{"node": "leaf01",
                                                       "attachment": "ethernet-1/1",
                                                       "vlan": 120}]}})
    report = await rig.create()
    assert report.status == "FAILED" and report.submitted is False
    assert report.retryable is False
    assert f"holder: Network {SERVICES_NS}/lab-macvrf" in (report.causes or [])
    assert f"{SERVICES_NS}/lab-macvrf" in (report.message or "")
    assert rig.api.network_writes() == [] and rig.api.calls("DELETE") == []
    gate = await rig.gate(CID)
    assert gate.releasable == [CID]  # every provisional claim is released


async def test_the_preflight_refuses_a_second_owner_naming_the_incumbent_even_deleting() -> None:
    rig = Rig()
    incumbent = network_manifest("0123456789abcde")
    incumbent["metadata"]["labels"] = {"agentic-netops.io/correlation-id": OTHER_CID}
    incumbent["metadata"]["deletionTimestamp"] = "2026-09-24T11:59:00Z"
    rig.api.put(incumbent)
    report = await rig.create()
    assert report.status == "FAILED" and report.submitted is False
    assert "migr-0123456789abcde" in (report.message or "")
    assert "being deleted" in report.message and "one owner" in report.message
    assert rig.translator.calls == [] and rig.api.calls("PATCH") == []


async def test_a_translator_422_is_a_refusal_with_its_causes_and_nothing_submitted() -> None:
    rig = Rig()
    rig.translator.status = 422
    rig.translator.causes = ["input[0]: unsupported feature: traffic-engineering"]
    report = await rig.create()
    assert report.status == "FAILED" and report.causes == rig.translator.causes
    assert rig.api.calls("PATCH") == []


async def test_a_resumed_request_is_not_resubmitted() -> None:
    rig = Rig()
    await _converged(rig)
    patches = len(rig.api.calls("PATCH"))
    again = await rig.create()
    assert again.status == "COMPLETED"
    assert len(rig.api.calls("PATCH")) == patches


async def test_submission_is_audited_as_a_span_event_and_mirrored_as_a_kubernetes_event(
        fresh_telemetry: Any) -> None:
    rig = Rig()
    await _converged(rig)
    (submit,) = [a for n, a in span_events(fresh_telemetry) if n == "audit.submit"]
    assert submit["audit.correlation_id"] == CID and submit["audit.principal"] == "alice"
    # the stream carries the submitted-spec hash the object's annotation holds (data-model §16)
    annotations = rig.api.networks[NETWORK]["metadata"]["annotations"]
    assert submit["audit.submitted_spec_sha256"] == annotations[
        "agentic-netops.io/intent-submitted-spec-sha256"]
    (event,) = rig.api.events
    assert event["reason"] == "IntentSubmitted" and event["metadata"]["namespace"] == NS
    assert event["involvedObject"]["name"] == NETWORK


def test_the_naming_and_allocation_vlan_bands_are_disjoint() -> None:
    """No allocated-versus-named VLAN fixture exists because the case cannot occur (AD-33)."""
    try:
        from provisioning.allocator.profiles import ALLOCATION_BAND, NAMING_BAND

        allocator = range(ALLOCATION_BAND[0], ALLOCATION_BAND[1] + 1)
        named = range(NAMING_BAND[0], NAMING_BAND[1] + 1)
    except ImportError:  # the allocator's constants not present: the contract's values
        allocator, named = range(1000, 4001), range(100, 1000)
    assert (min(allocator), max(allocator)) == (1000, 4000)
    assert (min(named), max(named)) == (100, 999)
    assert set(allocator).isdisjoint(named)
    assert list(ALLOCATION_VLAN_BAND) == list(allocator)
    assert list(NAMING_VLAN_BAND) == list(named)
