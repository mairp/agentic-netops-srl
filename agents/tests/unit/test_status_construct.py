"""T121 — a service stored under a retired type is reported by its construct, derived when it is
read, with the stored vocabulary as provenance; its stored record is never written (FR-026, FR-027,
SC-033; quickstart.md §14; the Go twin is pkg/fabricapi/construct_test.go).

A ``Network`` created before the vocabulary changed carries ``agentic-netops.io/service-type:
L2VNI`` (or ``VPLS``, ``L2L3-IRB``, …). A status request must name the construct — never present
the retired name as a type, only as provenance — and must write nothing: zero write calls to the
API server and the stored annotations byte-identical after the read.
"""

from __future__ import annotations

import copy
import json
from typing import Any

import pytest

from provisioning.deployer.stamp import SPEC_HASH_ANNOTATION, canonical_json, spec_sha256
from provisioning.deployer.status import (
    LIMITED_EQUIVALENCE_ANNOTATION,
    SERVICE_TYPE_ANNOTATION,
    SOURCE_SERVICE_TYPE_ANNOTATION,
    derive_construct,
)
from supervisors.provisioning.graph.nodes import _status_answer
from tests.unit.deployer_fakes import NETWORK, Rig, network_manifest

pytestmark = pytest.mark.usefixtures("fresh_telemetry")

# (stored service type, construct it is reported as, provenance) — every retired value the
# predecessor could have stored, the synonyms, and the constructs themselves.
RETIRED = [
    ("L2VNI", "mac-vrf", "L2VNI"),
    ("l2vni", "mac-vrf", "l2vni"),
    ("L3VNI", "ip-vrf", "L3VNI"),
    ("access-list", "acl", "access-list"),
    ("VPLS", "mac-vrf", "VPLS"),
    ("VPWS", "mac-vrf", "VPWS"),
    ("E-LINE", "mac-vrf", "VPWS"),
    ("L3VPN", "ip-vrf", "L3VPN"),
    ("L2L3-IRB", "mac-vrf", "L2L3-IRB"),
    ("IRB", "mac-vrf", "L2L3-IRB"),
]


def _obj(annotations: dict[str, str] | None, spec: dict[str, Any] | None = None
         ) -> dict[str, Any]:
    obj = network_manifest()
    if spec is not None:
        obj["spec"] = spec
    if annotations is None:
        obj["metadata"].pop("annotations")
    else:
        obj["metadata"]["annotations"] = annotations
    return obj


def _pre_existing(rig: Rig, stored: str, **extra: str) -> dict[str, Any]:
    """A converged Network the tier submitted before the vocabulary changed."""
    obj = network_manifest()
    obj["metadata"]["annotations"][SERVICE_TYPE_ANNOTATION] = stored
    obj["metadata"]["annotations"].update(extra)
    obj["metadata"]["annotations"][SPEC_HASH_ANNOTATION] = spec_sha256(obj["spec"])
    rig.api.put(obj)
    rig.api.set_ready(NETWORK, "True", "Converged", "every target read back")
    return rig.api.networks[NETWORK]


@pytest.mark.parametrize(("stored", "construct", "provenance"), RETIRED)
def test_a_retired_stored_type_derives_its_construct_with_provenance(
        stored: str, construct: str, provenance: str) -> None:
    obj = _obj({SERVICE_TYPE_ANNOTATION: stored})
    before = copy.deepcopy(obj)
    view = derive_construct(obj)
    assert obj == before  # a pure read
    assert (view.construct, view.provenance, view.retired) == (construct, provenance, True)
    assert view.stored_type == stored and not view.unknown and not view.derived


@pytest.mark.parametrize(("annotations", "spec", "expected"), [
    ({SERVICE_TYPE_ANNOTATION: "mac-vrf"}, None, ("mac-vrf", None, False, False, False)),
    ({SERVICE_TYPE_ANNOTATION: "MAC_VRF"}, None, ("mac-vrf", None, False, False, False)),
    ({SERVICE_TYPE_ANNOTATION: "mac-vrf", SOURCE_SERVICE_TYPE_ANNOTATION: "VPLS"}, None,
     ("mac-vrf", "VPLS", False, False, False)),
    (None, None, ("mac-vrf", None, False, True, False)),
    ({}, {"vlans": [{"name": "v", "vlan": 130}]}, ("vlan", None, False, True, False)),
    ({}, {"routers": [{"name": "r", "l3vni": 10200}]}, ("ip-vrf", None, False, True, False)),
    ({}, {"accessLists": [{"name": "a"}]}, ("acl", None, False, True, False)),
    ({}, {}, (None, None, False, False, False)),
    # unknown: reported unknown, never guessed from the (mac-vrf) spec
    ({SERVICE_TYPE_ANNOTATION: "EVPN-VPWS-FXC"}, None, (None, None, False, False, True)),
])
def test_constructs_aliases_absent_and_unknown_stored_types(
        annotations: dict[str, str] | None, spec: dict[str, Any] | None,
        expected: tuple[Any, ...]) -> None:
    view = derive_construct(_obj(annotations, spec))
    assert (view.construct, view.provenance, view.retired, view.derived, view.unknown) == expected


def test_derivation_tolerates_unexpected_shapes() -> None:
    for obj in (None, {}, {"metadata": "x"}, {"metadata": {"annotations": ["x"]}},
                {"metadata": {"annotations": {SERVICE_TYPE_ANNOTATION: 7}}}):
        view = derive_construct(obj)  # type: ignore[arg-type]
        assert view.construct is None and not view.unknown and view.provenance is None


@pytest.mark.parametrize(("stored", "construct", "provenance"), RETIRED)
async def test_status_names_the_construct_and_writes_nothing(
        stored: str, construct: str, provenance: str) -> None:
    rig = Rig()
    live = _pre_existing(rig, stored)
    stored_annotations = canonical_json(live["metadata"]["annotations"])
    stored_object = copy.deepcopy(live)
    report = await rig.status()
    assert rig.api.network_writes() == []  # zero write calls: no PATCH, PUT, POST or DELETE
    assert rig.api.calls("PATCH") == rig.api.calls("PUT") == rig.api.calls("POST") == []
    after = rig.api.networks[NETWORK]
    assert canonical_json(after["metadata"]["annotations"]) == stored_annotations  # byte-identical
    assert after == stored_object
    assert after["metadata"]["annotations"][SERVICE_TYPE_ANNOTATION] == stored  # never rewritten

    assert report.state == "converged" and report.out_of_band is None
    assert report.service_type == construct and report.provenance == provenance
    assert (report.live or {})["construct"] == construct
    assert (report.live or {})["provenance"] == provenance
    message = report.message or ""
    assert message == (f"Network/{NETWORK} ({construct}; created as {provenance} — provenance, "
                       "not a type) is converged (Ready=True)")
    # FR-026: the retired name appears only inside the provenance phrase, never as the type
    assert message.replace(f"created as {provenance} — provenance", "").count(provenance) == 0


async def test_status_of_a_construct_record_carries_no_provenance() -> None:
    rig = Rig()
    _pre_existing(rig, "mac-vrf")
    report = await rig.status()
    assert report.service_type == "mac-vrf" and report.provenance is None
    assert report.message == f"Network/{NETWORK} (mac-vrf) is converged (Ready=True)"


async def test_status_carries_the_arrival_alias_and_limited_equivalence() -> None:
    rig = Rig()
    _pre_existing(rig, "mac-vrf", **{SOURCE_SERVICE_TYPE_ANNOTATION: "VPWS",
                                     LIMITED_EQUIVALENCE_ANNOTATION: "point-to-point"})
    report = await rig.status()
    assert report.service_type == "mac-vrf" and report.provenance == "VPWS"
    assert report.message == (f"Network/{NETWORK} (mac-vrf; created as VPWS — provenance, not a "
                              "type; limited equivalence: point-to-point) is converged "
                              "(Ready=True)")
    assert rig.api.network_writes() == []


async def test_an_unknown_stored_type_is_reported_unknown_not_guessed() -> None:
    rig = Rig()
    _pre_existing(rig, "EVPN-VPWS-FXC")
    report = await rig.status()
    assert report.service_type is None and report.provenance is None
    assert "construct unknown" in (report.message or "")
    assert rig.api.network_writes() == []


async def test_a_modified_retired_record_is_reported_by_construct_and_still_not_written() -> None:
    rig = Rig()
    live = _pre_existing(rig, "L2VNI")
    live["spec"]["attachments"][1]["attachment"] = "ethernet-1/3"  # edited behind the tier's back
    annotations = json.dumps(live["metadata"]["annotations"], sort_keys=True)
    report = await rig.status()
    assert report.out_of_band == "modified" and report.service_type == "mac-vrf"
    message = report.message or ""
    assert f"Live state: Network/{NETWORK} (mac-vrf; created as L2VNI — provenance" in message
    assert rig.api.network_writes() == []
    assert json.dumps(rig.api.networks[NETWORK]["metadata"]["annotations"],
                      sort_keys=True) == annotations


def test_the_supervisor_relays_the_construct_and_provenance() -> None:
    answer = _status_answer({"status": "COMPLETED", "state": "converged",
                             "service_type": "mac-vrf", "provenance": "L2VNI",
                             "message": "m"})
    assert answer["construct"] == "mac-vrf" and answer["provenance"] == "L2VNI"
    assert _status_answer({"status": "COMPLETED", "provenance": 3})["provenance"] is None
