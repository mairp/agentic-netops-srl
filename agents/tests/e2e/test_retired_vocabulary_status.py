"""T121 — a service that converged before the vocabulary changed reports its construct
(quickstart.md §14; FR-026, FR-027, SC-033).

Live: a ``mac-vrf`` ``Network`` is applied with ``kubectl`` into ``agentic-netops-intent`` as the
tier would have stored it before the change — its ``agentic-netops.io/service-type`` annotation
the retired ``L2VNI`` — and left to converge. Its stored record (resourceVersion, generation,
annotations, managedFields) is read; the tier is asked for its status through the operator surface
(``POST /agent/prompt/stream``); the answer must name the construct (``mac-vrf``) and present the
stored vocabulary only as provenance; the object is then re-read: nothing was written to it for a
naming change — annotations, labels, spec and generation identical, no non-status managedFields
entry changed, and the resourceVersion unchanged unless only the provider's status subresource
moved it. The object is deleted at the end.
"""

from __future__ import annotations

import json
import os
import random
import secrets
import subprocess
import time
from collections.abc import Iterator
from pathlib import Path
from typing import Any

import pytest
import tierflow as tf
from conftest import CONTEXT, INTENT_NS, kjson

from provisioning.deployer.stamp import SPEC_HASH_ANNOTATION, TIER_LABEL, TIER_VALUE, spec_sha256
from provisioning.deployer.status import SERVICE_TYPE_ANNOTATION

RESOURCE = "networks.fabric.agentic-netops.io"
PORT = "ethernet-1/1"  # the one tagged access port the Fabric inventory lists on each leaf
RETIRED = "L2VNI"      # a predecessor's stored service type for a mac-vrf
CONSTRUCT = "mac-vrf"
FABRIC_ASN = 65000
CONVERGE_S = 420


def record(name: str, payload: Any) -> None:
    evidence = os.environ.get("EVIDENCE_DIR")
    if evidence:
        path = Path(evidence) / "t121" / f"{name}.json"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(payload, indent=2, sort_keys=True, default=str) + "\n")


def free_identifiers() -> tuple[int, int]:
    """A named-band VLAN (900-999) and an L2VNI (19000-19999) no Network and no claim uses —
    bands the other suites do not draw from."""
    vlans: set[int] = set()
    vnis: set[int] = set()
    for item in kjson("get", RESOURCE, "-A")["items"]:
        spec = item.get("spec") or {}
        for a in spec.get("attachments") or []:
            if a.get("vlan"):
                vlans.add(int(a["vlan"]))
        for v in spec.get("vlans") or []:
            vlans.add(int(v["vlan"]))
        for bd in spec.get("bridgeDomains") or []:
            vlans.add(int(bd.get("vlan") or 0))
            vnis.add(int(bd.get("l2vni") or 0))
        for r in spec.get("routers") or []:
            vnis.add(int(r.get("l3vni") or 0))
    for claim in tf.claims():
        value = (claim.get("status") or {}).get("value")
        if value is not None and str(value).isdigit():
            vnis.add(int(value))
    vlan = random.choice([v for v in range(900, 1000) if v not in vlans])  # noqa: S311
    vni = random.choice([v for v in range(19000, 20000) if v not in vnis])  # noqa: S311
    return vlan, vni


def manifest(name: str, vlan: int, vni: int) -> dict[str, Any]:
    target = f"target:{FABRIC_ASN}:{vni}"
    return {
        "apiVersion": "fabric.agentic-netops.io/v1alpha1", "kind": "Network",
        "metadata": {
            "name": name, "namespace": INTENT_NS,
            "labels": {TIER_LABEL: TIER_VALUE},
            "annotations": {
                "agentic-netops.io/translator": "agentic-netops-migration-translator",
                "agentic-netops.io/translator-version": "v0.1.0",
                "agentic-netops.io/mapping-version": "v0.1.0",
                "agentic-netops.io/tenant": "acme",
                SERVICE_TYPE_ANNOTATION: RETIRED,  # stored before the vocabulary changed
            },
        },
        "spec": {
            "description": f"T121 pre-existing service, vlan {vlan} l2vni {vni}",
            "bridgeDomains": [{"name": f"bd{vlan}", "vlan": vlan, "l2vni": vni,
                               "evpn": {"routeTargets": {"import": [target],
                                                         "export": [target]}}}],
            "attachments": [{"node": "leaf01", "attachment": PORT, "vlan": vlan},
                            {"node": "leaf02", "attachment": PORT, "vlan": vlan}],
        },
    }


def kubectl_stdin(*args: str, body: dict[str, Any]) -> str:
    proc = subprocess.run(["kubectl", "--context", CONTEXT, *args],  # noqa: S603, S607
                          input=json.dumps(body), capture_output=True, text=True, timeout=120)
    assert proc.returncode == 0, f"kubectl {' '.join(args)}: {proc.stderr.strip()}"
    return proc.stdout


def apply_pre_existing(obj: dict[str, Any]) -> None:
    """Stored as the tier stored it: the submitted-spec hash over the spec the server's dry-run
    returns, so the status answer is the live state and not an out-of-band modification."""
    dry = json.loads(kubectl_stdin("apply", "--dry-run=server", "-o", "json", "-f", "-",
                                   body=obj))
    obj["metadata"]["annotations"][SPEC_HASH_ANNOTATION] = spec_sha256(dry["spec"])
    kubectl_stdin("apply", "-f", "-", body=obj)


def ready(name: str) -> str | None:
    obj = tf.network(name) or {}
    for c in (obj.get("status") or {}).get("conditions") or []:
        if c.get("type") == "Ready":
            return c.get("status")
    return None


def snapshot(name: str) -> dict[str, Any]:
    obj = kjson("-n", INTENT_NS, "get", RESOURCE, name, "--show-managed-fields")
    meta = obj["metadata"]
    return {"resourceVersion": meta["resourceVersion"], "generation": meta["generation"],
            "managedFields": meta.get("managedFields") or [], "spec": obj["spec"],
            "annotations": meta.get("annotations") or {}, "labels": meta.get("labels") or {}}


def non_status(snap: dict[str, Any]) -> list[tuple[str, str, str, str]]:
    """Every managedFields entry that is not a status-subresource write, comparably."""
    return sorted((m["manager"], m["operation"], m.get("time", ""),
                   json.dumps(m.get("fieldsV1"), sort_keys=True))
                  for m in snap["managedFields"] if m.get("subresource") != "status")


def stage_chunk(turn: tf.Turn) -> dict[str, Any]:
    stages = [c for c in turn.chunks if c.get("type") == "stage" and c.get("stage") == "deployer"]
    assert stages, f"no deployer stage chunk:\n{turn.text()}"
    return stages[-1]


@pytest.fixture
def pre_existing() -> Iterator[dict[str, Any]]:
    name = f"migr-{secrets.token_hex(8)[:15]}"
    vlan, vni = free_identifiers()
    obj = manifest(name, vlan, vni)
    apply_pre_existing(obj)
    try:
        yield {"name": name, "vlan": vlan, "vni": vni, "manifest": obj}
    finally:
        if tf.network(name) is not None:
            tf.delete_with_kubectl(name)
            tf.wait_gone(name)


def test_a_retired_stored_type_is_reported_by_its_construct_and_never_written(
        pre_existing: dict[str, Any]) -> None:
    name = pre_existing["name"]
    deadline = time.monotonic() + CONVERGE_S
    while ready(name) != "True" and time.monotonic() < deadline:
        time.sleep(5)
    assert ready(name) == "True", f"Network/{name} did not converge: {tf.network(name)}"

    before = snapshot(name)
    assert before["annotations"][SERVICE_TYPE_ANNOTATION] == RETIRED

    turn = tf.status(name)
    chunk = stage_chunk(turn)
    after = snapshot(name)
    record("retired-vocabulary-status", {"network": name, "vlan": pre_existing["vlan"],
                                         "l2vni": pre_existing["vni"], "chunks": turn.chunks,
                                         "before": before, "after": after})

    # the status the operator is shown names the construct; the stored name is provenance only
    payload = chunk.get("payload") or {}
    message = payload.get("message") or chunk.get("message") or ""
    assert chunk.get("out_of_band") is None, turn.text()
    assert payload.get("construct") == CONSTRUCT, payload
    assert payload.get("provenance") == RETIRED, payload
    assert payload.get("state") == "converged", payload
    assert f"Network/{name} ({CONSTRUCT}; created as {RETIRED} — provenance" in message, message
    final = turn.last()
    assert final.get("type") == "final" and final.get("message") == message, turn.text()
    for c in turn.chunks:  # FR-026: the retired name is never presented as the type
        text = json.dumps(c)
        assert text.count(RETIRED) == text.count(f"created as {RETIRED}") + \
            text.count(f'"provenance": "{RETIRED}"'), c

    # FR-027: the stored record is unchanged — no converged service was written for a naming
    # change: not the annotation, not the spec, not a field manager, not a generation
    assert after["annotations"] == before["annotations"]
    assert after["annotations"][SERVICE_TYPE_ANNOTATION] == RETIRED
    assert after["labels"] == before["labels"]
    assert after["generation"] == before["generation"]
    assert after["spec"] == before["spec"]
    assert before["managedFields"] and after["managedFields"], "no managedFields read"
    assert non_status(after) == non_status(before), (
        f"a non-status managedFields entry changed:\n{non_status(before)}\n{non_status(after)}")
    if after["resourceVersion"] != before["resourceVersion"]:
        # the provider's own status refresh is not a write to the stored record; anything else is
        moved = [m for m in after["managedFields"] if m not in before["managedFields"]]
        assert moved and all(m.get("subresource") == "status" for m in moved), (
            f"resourceVersion {before['resourceVersion']} -> {after['resourceVersion']} "
            f"moved by a non-status write: {moved}")
