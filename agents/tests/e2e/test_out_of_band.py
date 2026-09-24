"""T103 — an out-of-band edit and delete are detected, reported, counted, never reverted
(quickstart.md §26; FR-105, FR-101, SC-030 out-of-band half; data-model.md §16).

Live: one ``vlan`` provisioned through the tier is edited with ``kubectl patch``; a status request
must say "modified outside the intent tier" (chunk ``out_of_band: "modified"``) and report the live
state, and the tier must write NOTHING to the object (managedFields and resourceVersion). A removal
of the modified service states the out-of-band change in its first confirmation and deletes nothing
on that turn; a decline leaves the object untouched; a second removal through both confirmations
deletes it. A second service deleted with ``kubectl delete`` is reported "deleted outside the intent
tier" (``out_of_band: "deleted"``) and not re-created. Both changes are counted in
``agentic_netops_agent_out_of_band_changes_total{change}`` and recorded as ``out_of_band`` audit
events — both read from the analytics store.
"""

from __future__ import annotations

import json
import os
import random
import time
from pathlib import Path
from typing import Any

import pytest
import tierflow as tf
from conftest import INTENT_NS, kjson, kubectl, wait_for

from provisioning.deployer.stamp import SPEC_HASH_ANNOTATION, spec_sha256

RESOURCE = "networks.fabric.agentic-netops.io"
PORT = "ethernet-1/1"  # the one tagged access port the Fabric inventory lists on each leaf


def record(name: str, payload: Any) -> None:
    evidence = os.environ.get("EVIDENCE_DIR")
    if evidence:
        path = Path(evidence) / "t103" / f"{name}.json"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(payload, indent=2, sort_keys=True, default=str) + "\n")


def free_vlans(count: int) -> list[int]:
    """VLANs in the naming band no Network in any namespace uses on the port."""
    used: set[int] = set()
    for item in kjson("get", RESOURCE, "-A")["items"]:
        for a in item["spec"].get("attachments") or []:
            if a.get("vlan"):
                used.add(int(a["vlan"]))
        for v in item["spec"].get("vlans") or []:
            used.add(int(v["vlan"]))
    pool = [v for v in range(600, 900) if v not in used]
    return random.sample(pool, count)


def snapshot(name: str) -> dict[str, Any]:
    obj = kjson("-n", INTENT_NS, "get", RESOURCE, name, "--show-managed-fields")
    meta = obj["metadata"]
    return {"resourceVersion": meta["resourceVersion"], "generation": meta["generation"],
            "deletionTimestamp": meta.get("deletionTimestamp"),
            "managedFields": meta.get("managedFields") or [], "spec": obj["spec"],
            "annotations": meta.get("annotations") or {}}


def spec_managers(snap: dict[str, Any]) -> list[tuple[str, str, str, str]]:
    """Every managedFields entry that is not a status-subresource write, as comparable tuples."""
    return sorted((m["manager"], m["operation"], m.get("time", ""),
                   json.dumps(m.get("fieldsV1"), sort_keys=True))
                  for m in snap["managedFields"] if m.get("subresource") != "status")


def assert_zero_tier_writes(before: dict[str, Any], after: dict[str, Any], what: str) -> None:
    assert before["managedFields"] and after["managedFields"], f"{what}: no managedFields read"
    assert after["generation"] == before["generation"], f"{what}: generation moved"
    assert after["spec"] == before["spec"], f"{what}: the spec was reverted or rewritten"
    assert after["annotations"] == before["annotations"], f"{what}: annotations rewritten"
    assert spec_managers(after) == spec_managers(before), (
        f"{what}: a non-status managedFields entry changed:\n{spec_managers(before)}\n"
        f"{spec_managers(after)}")
    managers_before = {m["manager"] for m in before["managedFields"]}
    new = {m["manager"] for m in after["managedFields"]} - managers_before
    assert not new, f"{what}: new field manager(s) {new}"
    if after["resourceVersion"] != before["resourceVersion"]:
        # allowed only for provider status updates: the only entries whose time moved are status
        moved = [m for m in after["managedFields"] if m not in before["managedFields"]]
        assert all(m.get("subresource") == "status" for m in moved), (
            f"{what}: resourceVersion moved by a non-status write: {moved}")


def stage_chunk(turn: tf.Turn) -> dict[str, Any]:
    stages = [c for c in turn.chunks if c.get("type") == "stage" and c.get("stage") == "deployer"]
    assert stages, f"no deployer stage chunk:\n{turn.text()}"
    return stages[-1]


def audit_out_of_band(network: str, reason: str, since: float) -> list[dict[str, Any]]:
    found = []
    for e in tf.audit_events():
        if e["name"] != "audit.out_of_band":
            continue
        a = e["attrs"]
        if a.get("audit.reason") == reason and network in a.get("audit.resources", "") and \
                _epoch(a.get("audit.at", "")) >= since:
            found.append(e)
    return found


def _epoch(at: str) -> float:
    from datetime import datetime

    try:
        return datetime.fromisoformat(at).timestamp()
    except ValueError:
        return 0.0


def wait_counter(change: str, above: float, timeout: float = 180) -> float:
    """The metric reaches the store on the exporter's period (60 s by default)."""
    deadline = time.monotonic() + timeout
    value = tf.out_of_band_total(change)
    while value <= above and time.monotonic() < deadline:
        time.sleep(10)
        value = tf.out_of_band_total(change)
    return value


def provision(vlan: int) -> tf.Service:
    prompt = (f"Create a vlan for tenant acme on leaf01 {PORT} and leaf02 {PORT} "
              f"with VLAN {vlan}")
    last: Exception | None = None
    for _ in range(2):
        try:
            svc = tf.provision(prompt)
            assert svc.network, "no Network named in the deployment turn"
            return svc
        except AssertionError as exc:  # a clarification or a model hiccup: a fresh thread
            last = exc
    raise AssertionError(f"could not provision VLAN {vlan}: {last}")


@pytest.fixture(scope="module")
def created() -> Any:
    names: list[str] = []
    yield names
    for name in names:  # clean-up of what a failed case left behind
        if tf.network(name) is not None:
            tf.remove(name)
            if tf.network(name) is not None:
                tf.delete_with_kubectl(name)


def test_modified_out_of_band_is_reported_counted_and_never_reverted(created: list[str]) -> None:
    started = time.time()
    vlan_a, vlan_b = free_vlans(2)
    svc = provision(vlan_a)
    name = str(svc.network)
    created.append(name)
    at_submission = snapshot(name)
    submitted = at_submission["annotations"][SPEC_HASH_ANNOTATION]
    assert submitted == spec_sha256(at_submission["spec"])
    counter_before = tf.out_of_band_total("modified")

    kubectl("-n", INTENT_NS, "patch", RESOURCE, name, "--type=merge",
            "-p", json.dumps({"spec": {"description": "edited by hand"}}))
    after_patch = snapshot(name)
    live_hash = spec_sha256(after_patch["spec"])
    assert live_hash != submitted

    turn = tf.status(name)
    chunk = stage_chunk(turn)
    after_status = snapshot(name)
    record("oob-modified-status", {"network": name, "vlan": vlan_a, "chunks": turn.chunks,
                                   "at_submission": at_submission, "after_patch": after_patch,
                                   "after_status": after_status})
    assert chunk.get("out_of_band") == "modified", turn.text()
    payload = chunk.get("payload") or {}
    message = payload.get("message") or chunk.get("message") or ""
    assert "modified outside the intent tier" in message, turn.text()
    # the live state, never the remembered one: the live hash, and the live readiness after it
    assert live_hash in message and submitted in message, message
    assert "Live state:" in message and payload.get("state") in (
        "converged", "progressing", "unknown"), payload
    assert after_status["spec"]["description"] == "edited by hand"  # not reverted
    assert_zero_tier_writes(after_patch, after_status, "status turn")

    # a removal of the modified service: the detecting turn deletes nothing
    first = tf.ask(f"Remove the service {name}")
    conf = first.confirmation()
    assert conf and conf.get("stage") == "deployer", first.text()
    assert "modified outside the intent tier" in conf["prompt"], conf
    assert stage_chunk(first).get("out_of_band") == "modified"
    assert (stage_chunk(first).get("payload") or {}).get("statement"), first.text()
    after_first = snapshot(name)
    assert after_first["deletionTimestamp"] is None
    assert_zero_tier_writes(after_status, after_first, "removal's detecting turn")
    declined = tf.ask("no", first.thread_id)
    after_decline = snapshot(name)
    record("oob-removal-declined", {"first": first.chunks, "decline": declined.chunks,
                                    "after_decline": after_decline})
    assert declined.last().get("status") != "COMPLETED", declined.text()
    assert after_decline["deletionTimestamp"] is None
    assert_zero_tier_writes(after_status, after_decline, "declined removal")

    # a second removal through both confirmations deletes it
    turns = tf.remove(name)
    record("oob-removal-confirmed", {"turns": [t.chunks for t in turns]})
    assert len(turns) == 3, "\n".join(t.text() for t in turns)
    assert "modified outside the intent tier" in (turns[0].confirmation() or {}).get("prompt", "")
    assert turns[-1].last().get("status") == "COMPLETED", turns[-1].text()
    tf.wait_gone(name)

    events = audit_out_of_band(name, "modified", started)
    if not events:
        wait_for("the out_of_band audit event in the store",
                 lambda: bool(audit_out_of_band(name, "modified", started)), timeout=120, every=5)
        events = audit_out_of_band(name, "modified", started)
    principal = tf.operator_login()[0]
    assert all(e["service"] == "deployer" for e in events)
    assert any(e["attrs"].get("audit.principal") == principal for e in events)
    counter_after = wait_counter("modified", counter_before)
    record("oob-modified-counted", {"events": events, "counter_before": counter_before,
                                    "counter_after": counter_after})
    assert counter_after > counter_before, (counter_before, counter_after)
    pytest.vlan_b = vlan_b  # type: ignore[attr-defined]


def test_deleted_out_of_band_is_reported_counted_and_not_recreated(created: list[str]) -> None:
    started = time.time()
    vlan = getattr(pytest, "vlan_b", None) or free_vlans(1)[0]
    svc = provision(vlan)
    name = str(svc.network)
    created.append(name)
    counter_before = tf.out_of_band_total("deleted")

    tf.delete_with_kubectl(name)
    tf.wait_gone(name)
    turn = tf.status(name)
    chunk = stage_chunk(turn)
    record("oob-deleted-status", {"network": name, "vlan": vlan, "chunks": turn.chunks})
    assert chunk.get("out_of_band") == "deleted", turn.text()
    message = (chunk.get("payload") or {}).get("message") or chunk.get("message") or ""
    assert "deleted outside the intent tier" in message, turn.text()
    time.sleep(10)
    assert tf.network(name) is None, "the tier re-created an out-of-band deletion"

    wait_for("the out_of_band deleted audit event in the store",
             lambda: bool(audit_out_of_band(name, "deleted", started)), timeout=120, every=5)
    counter_after = wait_counter("deleted", counter_before)
    record("oob-deleted-counted", {"events": audit_out_of_band(name, "deleted", started),
                                   "counter_before": counter_before,
                                   "counter_after": counter_after})
    assert counter_after > counter_before, (counter_before, counter_after)
